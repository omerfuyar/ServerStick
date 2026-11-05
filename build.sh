#!/usr/bin/env bash
# Build the ServerStick ISO natively on an Arch-based host.
# Usage: ./build.sh   (run as your normal user; asks for sudo once)
set -euo pipefail

ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
cd "$ROOT"
PROFILE="$ROOT/build/profile"
WORK="$ROOT/work"
OUT="$ROOT/out"

BASE_PACKAGES=(tailscale openssh nvidia-open nvidia-utils btop nvtop lm_sensors pciutils tmux git python)

die()  { echo "ERROR: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ $EUID -ne 0 ]] || die "run build.sh as your normal user; it calls sudo itself"

# ---------------------------------------------------------------- config
step "Reading .env"
[[ -f .env ]] || die ".env not found. Run: cp .env.example .env  and set TS_AUTHKEY"
set -a
# shellcheck disable=SC1091
source ./.env
set +a

TS_AUTHKEY="${TS_AUTHKEY:-}"
TS_HOSTNAME="${TS_HOSTNAME:-stickserver}"
EXTRA_PACKAGES="${EXTRA_PACKAGES:-}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"
COW_SPACESIZE="${COW_SPACESIZE:-50%}"

[[ -n "$TS_AUTHKEY" ]] || die "TS_AUTHKEY is missing in .env"
[[ "$TS_AUTHKEY" == tskey-* ]] || die "TS_AUTHKEY must start with 'tskey-' (got '${TS_AUTHKEY:0:6}...')"
[[ "$TS_AUTHKEY" != *REPLACE-ME* ]] || die "TS_AUTHKEY is still the placeholder from .env.example"
[[ "$TS_AUTHKEY" =~ ^[A-Za-z0-9_-]+$ ]] || die "TS_AUTHKEY contains unexpected characters (spaces/quotes?)"
[[ "$TS_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
    || die "TS_HOSTNAME '$TS_HOSTNAME' is not a valid hostname (letters, digits, '-', max 63)"
read -r -a EXTRA <<<"$EXTRA_PACKAGES"
for p in "${EXTRA[@]}"; do
    [[ "$p" =~ ^[a-z0-9@._+-]+$ ]] || die "EXTRA_PACKAGES: invalid package name '$p'"
done
if [[ -n "$WIFI_SSID" || -n "$WIFI_PASSWORD" ]]; then
    [[ -n "$WIFI_SSID" && -n "$WIFI_PASSWORD" ]] || die "set both WIFI_SSID and WIFI_PASSWORD, or neither"
    ((${#WIFI_PASSWORD} >= 8 && ${#WIFI_PASSWORD} <= 63)) || die "WIFI_PASSWORD must be 8-63 characters"
    [[ "$WIFI_PASSWORD" != *$'\n'* ]] || die "WIFI_PASSWORD must not contain newlines"
fi
[[ "$COW_SPACESIZE" =~ ^([1-9][0-9]?%|100%|[1-9][0-9]*[KMG])$ ]] \
    || die "COW_SPACESIZE '$COW_SPACESIZE' must be a percentage of RAM (1%-100%) or a size like 512M / 8G"
BOOT_PARAMS="copytoram=y cow_spacesize=${COW_SPACESIZE} systemd.gpt_auto=0 systemd.swap=0"
echo "hostname=$TS_HOSTNAME  extra packages=${EXTRA[*]:-none}  wifi=${WIFI_SSID:-off}  cow_spacesize=$COW_SPACESIZE"

# The overlay holds tracked symlinks; they are lost on exFAT/NTFS checkouts.
[[ -L overlay/airootfs/etc/systemd/system/multi-user.target.wants/tailscaled.service ]] \
    || die "overlay symlinks are missing. Keep the repo on a Linux filesystem (ext4/btrfs), not exFAT/NTFS."

# ---------------------------------------------------------------- host tools
step "Checking host tools"
if ! command -v mkarchiso >/dev/null || ! command -v unsquashfs >/dev/null || ! command -v xorriso >/dev/null; then
    echo "Installing archiso (needs sudo)"
    sudo pacman -S --needed --noconfirm archiso
fi
[[ -d /usr/share/archiso/configs/releng ]] || die "/usr/share/archiso/configs/releng not found"

# Ask for sudo once and keep it alive while mkarchiso runs.
sudo -v
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill $SUDO_KEEPALIVE 2>/dev/null || true' EXIT

# ---------------------------------------------------------------- profile
step "Assembling profile in build/profile"
rm -rf "$PROFILE"
mkdir -p "$ROOT/build"
cp -a /usr/share/archiso/configs/releng "$PROFILE"
cp -a overlay/airootfs/. "$PROFILE/airootfs/"
A="$PROFILE/airootfs"

# sshd: only Tailscale SSH reaches this box. cloud-init: never read config from local disks.
rm -f "$A/etc/systemd/system/multi-user.target.wants/sshd.service"
rm -rf "$A/etc/systemd/system/cloud-init.target.wants"
# releng still enables hv_fcopy_daemon.service, which the hyperv package no longer ships (dangling link).
rm -f "$A/etc/systemd/system/multi-user.target.wants/hv_fcopy_daemon.service"

step "Rendering templated files"
echo "$TS_HOSTNAME" >"$A/etc/hostname"
(
    umask 077
    mkdir -p "$A/etc/tailscale"
    printf '%s' "$TS_AUTHKEY" >"$A/etc/tailscale/authkey"
)
printf 'TS_HOSTNAME=%s\n' "$TS_HOSTNAME" >"$A/etc/tailscale/autojoin.env"

PERMS=(
    '["/etc/tailscale"]="0:0:700"'
    '["/etc/tailscale/authkey"]="0:0:600"'
    '["/usr/local/bin/tailscale-autojoin"]="0:0:755"'
    '["/usr/local/bin/serverstick-status"]="0:0:755"'
)
if [[ -n "$WIFI_SSID" ]]; then
    # iwd file name: plain SSID if it only has [A-Za-z0-9 _-], else "=" + hex.
    if [[ "$WIFI_SSID" =~ ^[A-Za-z0-9\ _-]+$ ]]; then
        psk_name="$WIFI_SSID.psk"
    else
        psk_name="=$(printf '%s' "$WIFI_SSID" | od -An -tx1 -v | tr -d ' \n').psk"
    fi
    (
        umask 077
        mkdir -p "$A/var/lib/iwd"
        printf '[Security]\nPassphrase=%s\n' "$WIFI_PASSWORD" >"$A/var/lib/iwd/$psk_name"
    )
    PERMS+=('["/var/lib/iwd"]="0:0:700"' "[\"/var/lib/iwd/$psk_name\"]=\"0:0:600\"")
    echo "wifi profile: /var/lib/iwd/$psk_name"
fi

step "Patching profiledef.sh"
sed -i \
    -e 's/^iso_name=.*/iso_name="serverstick"/' \
    -e 's/^iso_application=.*/iso_application="ServerStick headless Tailscale node"/' \
    "$PROFILE/profiledef.sh"
{
    echo
    echo "# ServerStick"
    echo "file_permissions+=("
    printf '  %s\n' "${PERMS[@]}"
    echo ")"
} >>"$PROFILE/profiledef.sh"

step "Adding packages"
printf '%s\n' "${BASE_PACKAGES[@]}" "${EXTRA[@]}" >>"$PROFILE/packages.x86_64"
awk 'NF && !seen[$0]++' "$PROFILE/packages.x86_64" >"$PROFILE/packages.x86_64.new"
mv "$PROFILE/packages.x86_64.new" "$PROFILE/packages.x86_64"

step "Patching boot entries: $BOOT_PARAMS"
mapfile -t BOOT_FILES < <(grep -rl 'archisobasedir=' "$PROFILE/efiboot" "$PROFILE/syslinux" "$PROFILE/grub" 2>/dev/null)
((${#BOOT_FILES[@]} > 0)) || die "no boot entries found in the releng profile"
for f in "${BOOT_FILES[@]}"; do
    sed -i "/archisobasedir=/ { /copytoram=/! s/[[:space:]]*\$/ ${BOOT_PARAMS}/ }" "$f"
    echo "  ${f#"$PROFILE/"}: $(grep -c 'copytoram=y' "$f") entr(y/ies)"
done

# ---------------------------------------------------------------- build
step "Running mkarchiso"
sudo rm -rf "$WORK"
mkdir -p "$OUT"
sudo mkarchiso -v -w "$WORK" -o "$OUT" "$PROFILE"

step "Cleaning up"
sudo rm -rf "$WORK"
sudo chown -R "$(id -u):$(id -g)" "$OUT"
ISO="$(ls -t "$OUT"/serverstick-*.iso | head -n1)"
echo "ISO: $ISO ($(du -h "$ISO" | cut -f1))"

step "Verifying"
"$ROOT/verify.sh" "$ISO"
