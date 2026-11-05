#!/usr/bin/env bash
# Write the ServerStick ISO to a USB drive, chosen from a list.
#
#   ./flash.sh [--all] [path/to.iso]
#
# By default only USB/removable drives are offered. --all also lists internal
# disks, but never the disk your running system lives on.
# Everything on the chosen drive is erased.
set -euo pipefail

ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
SHOW_ALL=0
if [[ "${1:-}" == "--all" ]]; then SHOW_ALL=1; shift; fi
ISO="${1:-$(ls -t "$ROOT"/out/serverstick-*.iso 2>/dev/null | head -n1 || true)}"

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -ne 0 ]] || die "run as your normal user; flash.sh calls sudo itself"
[[ -n "$ISO" && -f "$ISO" ]] || die "no ISO found. Build one with ./build.sh or pass a path"
ISO_BYTES="$(stat -c %s "$ISO")"
echo "ISO: $ISO ($(numfmt --to=iec "$ISO_BYTES"))"

# Disks that hold the running system (/, /boot, /home, /usr, /var, swap), through LVM/LUKS/RAID.
system_disks() {
    {
        for m in / /boot /boot/efi /efi /home /usr /var; do
            findmnt -nro SOURCE "$m" 2>/dev/null || true
        done
        swapon --noheadings --show=NAME 2>/dev/null || true
    } | sed 's/\[.*\]$//' | grep '^/dev/' | sort -u | while read -r dev; do
        lsblk -nrspo PATH,TYPE "$dev" 2>/dev/null | awk '$2 == "disk" {print $1}'
    done | sort -u
}
mapfile -t SYSTEM < <(system_disks)
is_system() { local d; for d in "${SYSTEM[@]}"; do [[ "$d" == "$1" ]] && return 0; done; return 1; }

# Build the candidate list.
CANDS=() LABELS=()
while IFS= read -r line; do
    eval "$line"   # sets PATH_ SIZE TYPE TRAN RM HOTPLUG MODEL (from lsblk -P, renamed below)
    dev="$PATH_"
    [[ "$TYPE" == disk ]] || continue
    [[ "$dev" == /dev/zram* || "$dev" == /dev/loop* ]] && continue
    is_system "$dev" && continue
    if ((SHOW_ALL == 0)) && [[ "$TRAN" != usb && "$RM" != 1 && "$HOTPLUG" != 1 ]]; then
        continue
    fi
    bytes="$(lsblk -bdno SIZE "$dev")"
    ((bytes >= ISO_BYTES)) || continue
    model="$(echo "$MODEL" | xargs)"
    parts="$(lsblk -nro LABEL,FSTYPE,MOUNTPOINT "$dev" | awk 'NF {printf "%s%s", sep, $0; sep="; "}')"
    CANDS+=("$dev")
    LABELS+=("$(printf '%-12s %8s  %-5s %-28s %s' "$dev" "$SIZE" "${TRAN:--}" "${model:-(no model)}" "${parts:+[$parts]}")")
done < <(lsblk -dnpP -o PATH,SIZE,TYPE,TRAN,RM,HOTPLUG,MODEL | sed 's/^PATH=/PATH_=/')

if ((${#CANDS[@]} == 0)); then
    echo "No suitable drive found (USB/removable, not your system disk, at least $(numfmt --to=iec "$ISO_BYTES"))."
    ((SHOW_ALL)) || echo "Plug in a USB stick, or use --all to also list internal disks."
    exit 1
fi

echo
echo "Drives you can write to (hidden: the disk your system runs from${SYSTEM[*]:+, $(printf "%s " "${SYSTEM[@]}" | xargs -n1 | grep -v zram | xargs)}):"
for i in "${!CANDS[@]}"; do
    printf '  %d) %s\n' "$((i + 1))" "${LABELS[$i]}"
done
echo
read -rp "Choose a drive [1-${#CANDS[@]}], or q to quit: " choice
[[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#CANDS[@]})) || { echo "Aborted."; exit 1; }
DEV="${CANDS[$((choice - 1))]}"

echo
echo "Selected: ${LABELS[$((choice - 1))]}"
echo "Current contents:"
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DEV" | sed 's/^/  /'
echo
echo "EVERYTHING ON $DEV WILL BE ERASED."
read -rp "Type the device name ($(basename "$DEV")) to confirm: " confirm
[[ "$confirm" == "$(basename "$DEV")" ]] || { echo "Aborted, nothing was written."; exit 1; }

# Unmount anything mounted from the drive.
mapfile -t MOUNTED < <(lsblk -nrpo PATH,MOUNTPOINT "$DEV" | awk 'NF == 2 {print $1}')
for p in "${MOUNTED[@]}"; do
    echo "Unmounting $p"
    if command -v udisksctl >/dev/null; then
        udisksctl unmount -b "$p" >/dev/null 2>&1 || sudo umount "$p"
    else
        sudo umount "$p"
    fi
done

echo "Writing $ISO -> $DEV"
sudo dd if="$ISO" of="$DEV" bs=4M conv=fsync oflag=direct status=progress
sync

echo "Verifying written data"
if sudo cmp -n "$ISO_BYTES" "$ISO" "$DEV"; then
    echo "OK: $DEV matches the ISO. You can unplug the drive."
else
    die "verification failed: $DEV does not match the ISO. Try again or use another stick."
fi
