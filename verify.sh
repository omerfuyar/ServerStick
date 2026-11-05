#!/usr/bin/env bash
# Check a built ServerStick ISO without booting it.
# Usage: ./verify.sh [path/to.iso]   (default: newest out/serverstick-*.iso)
set -euo pipefail

ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
ISO="${1:-$(ls -t "$ROOT"/out/serverstick-*.iso 2>/dev/null | head -n1 || true)}"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "ERROR: no ISO given and none found in out/" >&2; exit 1; }
for t in bsdtar unsquashfs xorriso mcopy python3; do
    command -v "$t" >/dev/null || { echo "ERROR: '$t' not found (install archiso)" >&2; exit 1; }
done

# Expected values from .env (only the non-secret ones).
EXTRA_PACKAGES="" WIFI_SSID="" TS_HOSTNAME="stickserver" COW_SPACESIZE="50%"
if [[ -f "$ROOT/.env" ]]; then
    eval "$(set -a; source "$ROOT/.env" >/dev/null 2>&1
            printf 'EXTRA_PACKAGES=%q WIFI_SSID=%q TS_HOSTNAME=%q COW_SPACESIZE=%q\n' \
                "${EXTRA_PACKAGES:-}" "${WIFI_SSID:-}" "${TS_HOSTNAME:-stickserver}" "${COW_SPACESIZE:-50%}")"
fi
BASE_PACKAGES="tailscale openssh nvidia-open nvidia-utils btop nvtop lm_sensors pciutils tmux git python"

T="$ROOT/build/verify"
# Files extracted from the ISO are read-only; make them writable before deleting.
wipe() { [[ -e "$1" ]] || return 0; chmod -R u+w "$1" 2>/dev/null || true; rm -rf "$1"; }
wipe "$T"
# Don't leave the extracted secret or the big squashfs copy around.
trap 'wipe "$T/root"; wipe "$T/iso"' EXIT
mkdir -p "$T/iso" "$T/esp" "$T/bootimg"
echo "Verifying $ISO"

echo "  extracting ISO filesystem"
bsdtar -xf "$ISO" -C "$T/iso" --exclude 'arch/boot/*' --exclude 'boot/memtest86+/*'
SFS="$(find "$T/iso" -name airootfs.sfs | head -n1)"
[[ -n "$SFS" ]] || { echo "ERROR: airootfs.sfs not found in ISO" >&2; exit 1; }

echo "  extracting EFI boot image(s)"
xorriso -osirrox on -indev "$ISO" -extract_boot_images "$T/bootimg/" >/dev/null 2>&1 || true
i=0
for img in "$T"/bootimg/*; do
    [[ -f "$img" ]] || continue
    if mcopy -s -n -i "$img" ::/loader "$T/esp/$i" 2>/dev/null; then
        i=$((i + 1))
    fi
done

echo "  listing squashfs"
unsquashfs -lln "$SFS" >"$T/sfs.list"
unsquashfs -q -n -d "$T/root" "$SFS" \
    etc/tailscale etc/hostname var/lib/iwd usr/local/bin/tailscale-autojoin >/dev/null 2>&1 || true

python3 -I - "$T" "$BASE_PACKAGES $EXTRA_PACKAGES" "$WIFI_SSID" "$TS_HOSTNAME" "$COW_SPACESIZE" <<'PY'
import os, posixpath, re, sys

T, packages, wifi_ssid, hostname, cow = sys.argv[1], sys.argv[2].split(), sys.argv[3], sys.argv[4], sys.argv[5]
fails = 0

def check(ok, msg):
    global fails
    print(("  PASS  " if ok else "  FAIL  ") + msg)
    if not ok:
        fails += 1

# --- squashfs listing: "<mode> <uid>/<gid> <size> <date> <time> squashfs-root/<path>[ -> target]"
entries = {}
line_re = re.compile(r"^(\S+)\s+(\d+)/(\d+)\s+\S+\s+\S+\s+\S+\s+squashfs-root(/.*?)(?: -> (.*))?$")
with open(os.path.join(T, "sfs.list")) as f:
    for line in f:
        m = line_re.match(line.rstrip("\n"))
        if m:
            mode, uid, gid, path, target = m.groups()
            entries[path] = (mode, int(uid), int(gid), target)
check(len(entries) > 1000, f"squashfs listing parsed ({len(entries)} entries)")

def resolve(path, depth=0):
    """Follow symlinks inside the image. Returns the final path or None."""
    if depth > 20 or path not in entries:
        return None
    target = entries[path][3]
    if not entries[path][0].startswith("l"):
        return path
    nxt = target if target.startswith("/") else posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
    return resolve(nxt, depth + 1)

# --- auth key
ak = entries.get("/etc/tailscale/authkey")
check(ak is not None, "/etc/tailscale/authkey exists")
if ak:
    check(ak[0] == "-rw-------" and ak[1] == 0 and ak[2] == 0, f"authkey mode/owner is -rw------- 0/0 (got {ak[0]} {ak[1]}/{ak[2]})")
    try:
        with open(os.path.join(T, "root/etc/tailscale/authkey")) as f:
            check(f.read().startswith("tskey-"), "authkey content starts with tskey-")
    except OSError as e:
        check(False, f"authkey readable from image ({e})")
env = entries.get("/etc/tailscale/autojoin.env")
check(env is not None, "/etc/tailscale/autojoin.env exists")
try:
    with open(os.path.join(T, "root/etc/hostname")) as f:
        got = f.read().strip()
    check(got == hostname, f"/etc/hostname is '{hostname}' (got '{got}')")
except OSError:
    check(False, "/etc/hostname exists")

# --- scripts and units
for p, mode in [("/usr/local/bin/tailscale-autojoin", "-rwxr-xr-x"),
                ("/usr/local/bin/serverstick-status", "-rwxr-xr-x"),
                ("/etc/systemd/system/tailscale-autojoin.service", None),
                ("/etc/profile.d/zz-serverstick-banner.sh", None),
                ("/usr/bin/tailscale", None), ("/usr/bin/tailscaled", None),
                ("/usr/bin/nvidia-smi", None)]:
    e = entries.get(p)
    if mode:
        check(e is not None and e[0] == mode, f"{p} exists with mode {mode}" + (f" (got {e[0]})" if e else ""))
    else:
        check(e is not None, f"{p} exists")

# --- every wants/ symlink resolves
wants = sorted(p for p in entries if re.match(r"^/etc/systemd/system/[^/]+\.wants/[^/]+$", p))
broken = [p for p in wants if entries[p][0].startswith("l") and resolve(p) is None]
check(not broken, f"all {len(wants)} systemd .wants symlinks resolve" + (f"; broken: {broken}" if broken else ""))

def enabled(unit, target):
    return f"/etc/systemd/system/{target}.wants/{unit}" in entries
for unit, target in [("tailscaled.service", "multi-user.target"),
                     ("tailscale-autojoin.service", "multi-user.target"),
                     ("systemd-networkd.service", "multi-user.target"),
                     ("systemd-resolved.service", "multi-user.target"),
                     ("iwd.service", "multi-user.target"),
                     ("systemd-networkd-wait-online.service", "network-online.target"),
                     ("systemd-timesyncd.service", "sysinit.target")]:
    check(enabled(unit, target), f"{unit} enabled ({target}.wants)")
check(not enabled("sshd.service", "multi-user.target"), "sshd.service NOT enabled")
check(not any(p.startswith("/etc/systemd/system/cloud-init.target.wants/") for p in entries), "cloud-init NOT enabled")

# --- disk safeguards: masks must shadow real rules
for rule in ["69-dm-lvm.rules", "64-md-raid-assembly.rules"]:
    check(f"/etc/udev/rules.d/{rule}" in entries and f"/usr/lib/udev/rules.d/{rule}" in entries,
          f"udev rule {rule} masked in /etc and present in /usr/lib")

# --- packages
local = {p.rsplit("/", 1)[1] for p in entries if re.match(r"^/var/lib/pacman/local/[^/]+$", p)}
for pkg in packages:
    found = any(re.fullmatch(re.escape(pkg) + r"-[^-]+-[^-]+", d) for d in local)
    check(found, f"package {pkg} installed")

# --- wifi
if wifi_ssid:
    psks = [p for p in entries if p.startswith("/var/lib/iwd/") and p.endswith(".psk")]
    check(len(psks) == 1 and entries[psks[0]][0] == "-rw-------", f"iwd psk file present with mode 0600 ({psks})")
else:
    check(not any(p.startswith("/var/lib/iwd/") and p.endswith(".psk") for p in entries), "no iwd psk file (wifi not configured)")

# --- boot entries (ISO tree + EFI system partition image)
counts = {}
bad = []
for base in ("iso", "esp"):
    for dirpath, _, files in os.walk(os.path.join(T, base)):
        for name in files:
            if not (name.endswith(".cfg") or name.endswith(".conf")):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, T)
            kind = "systemd-boot" if "/loader/" in path else "syslinux" if "syslinux" in path else "grub" if "grub" in path else "other"
            with open(path, errors="replace") as f:
                for n, line in enumerate(f, 1):
                    if "archisobasedir=" in line:
                        counts[kind] = counts.get(kind, 0) + 1
                        if "copytoram=y" not in line.split() or f"cow_spacesize={cow}" not in line.split():
                            bad.append(f"{rel}:{n}")
check(counts.get("syslinux", 0) > 0, f"syslinux (BIOS) boot entries found: {counts.get('syslinux', 0)}")
check(counts.get("systemd-boot", 0) > 0, f"systemd-boot (UEFI) boot entries found: {counts.get('systemd-boot', 0)}")
if counts.get("grub"):
    print(f"  info  grub boot entries found: {counts['grub']}")
check(not bad, f"all {sum(counts.values())} boot entries contain copytoram=y cow_spacesize={cow}" + (f"; missing in {bad}" if bad else ""))

print()
if fails:
    print(f"VERIFY FAILED: {fails} check(s) failed")
    sys.exit(1)
print("VERIFY OK")
PY
