#!/usr/bin/env bash
# Build the ServerStick ISO natively on an Arch-based host.
# Usage: ./build.sh   (run as your normal user; asks for sudo once)
set -euo pipefail

ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
cd "$ROOT"
PROFILE="$ROOT/build/profile"
WORK="$ROOT/work"
OUT="$ROOT/out"

mapfile -t BASE_PACKAGES < <(sed -e 's/#.*//' -e 's/[[:space:]]//g' "$ROOT/packages.txt" | grep -v '^$')
# Pre-installed into /root/.tmux/plugins (the ISO has no use for prefix+I at runtime).
TMUX_PLUGINS=(tmux-plugins/tpm tmux-plugins/tmux-sensible sunaku/tmux-navigate shivamashtikar/tmux-onedark-theme
    sainnhe/tmux-fzf shivamashtikar/tmux-tiling-revamped tmux-plugins/tmux-copycat tmux-plugins/tmux-open)

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
NET_FALLBACK="${NET_FALLBACK:-1}"

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
    [[ "$WIFI_SSID" != *$'\n'* ]] && (($(printf '%s' "$WIFI_SSID" | wc -c) <= 32)) \
        || die "WIFI_SSID must be at most 32 bytes, without newlines"
fi
[[ "$NET_FALLBACK" =~ ^[01]$ ]] || die "NET_FALLBACK must be 1 or 0"
[[ "$COW_SPACESIZE" =~ ^([1-9][0-9]?%|100%|[1-9][0-9]*[KMG])$ ]] \
    || die "COW_SPACESIZE '$COW_SPACESIZE' must be a percentage of RAM (1%-100%) or a size like 512M / 8G"
BOOT_PARAMS="copytoram=y cow_spacesize=${COW_SPACESIZE} systemd.gpt_auto=0 systemd.swap=0"
echo "hostname=$TS_HOSTNAME  extra packages=${EXTRA[*]:-none}  wifi=${WIFI_SSID:-off}  cow_spacesize=$COW_SPACESIZE  net_fallback=$NET_FALLBACK"

# The overlay holds tracked symlinks; they are lost on exFAT/NTFS checkouts.
[[ -L overlay/airootfs/etc/systemd/system/multi-user.target.wants/tailscaled.service ]] \
    || die "overlay symlinks are missing. Keep the repo on a Linux filesystem (ext4/btrfs), not exFAT/NTFS."

# ---------------------------------------------------------------- host tools
step "Checking host tools"
command -v git >/dev/null || die "git is needed to fetch the tmux plugins"
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
# NetworkManager (enabled by the overlay) replaces releng's systemd-networkd + iwd.
rm -f "$A/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" \
    "$A/etc/systemd/system/sockets.target.wants/systemd-networkd.socket" \
    "$A/etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service" \
    "$A/etc/systemd/system/dbus-org.freedesktop.network1.service" \
    "$A/etc/systemd/system/multi-user.target.wants/iwd.service"
rm -rf "$A/etc/systemd/network"
if [[ "$NET_FALLBACK" == 1 ]]; then
    ln -sfn ../netfind-fallback.service "$A/etc/systemd/system/multi-user.target.wants/netfind-fallback.service"
fi

step "Fetching tmux plugins"
for repo in "${TMUX_PLUGINS[@]}"; do
    git clone --quiet --depth 1 "https://github.com/$repo" "$A/root/.tmux/plugins/${repo#*/}" \
        || die "could not clone https://github.com/$repo"
    echo "  $repo"
done

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
    '["/usr/local/bin/netfind"]="0:0:755"'
)
# mkarchiso copies airootfs without file modes, so every executable in the plugins needs an entry.
while IFS= read -r f; do
    PERMS+=("[\"/${f#"$A/"}\"]=\"0:0:755\"")
done < <(find "$A/root/.tmux/plugins" -type f -perm -u+x -not -path '*/.git/*')
if [[ -n "$WIFI_SSID" ]]; then
    # NetworkManager keyfile. Plain SSID if simple, else a byte list; escape the passphrase for GKeyFile.
    if [[ "$WIFI_SSID" =~ ^[A-Za-z0-9_.-][A-Za-z0-9\ _.-]*$ ]]; then
        kf_ssid="$WIFI_SSID"
    else
        kf_ssid="$(printf '%s' "$WIFI_SSID" | od -An -tu1 -v | tr -s ' \n' ' ' | sed 's/^ //; s/ $//; s/ /;/g');"
    fi
    kf_psk="${WIFI_PASSWORD//\\/\\\\}"
    kf_psk="${kf_psk//$'\t'/\\t}"
    [[ "$kf_psk" == " "* ]] && kf_psk="\\s${kf_psk:1}"
    nm_file="$A/etc/NetworkManager/system-connections/serverstick-wifi.nmconnection"
    (
        umask 077
        mkdir -p "$(dirname "$nm_file")"
        printf '[connection]\nid=serverstick-wifi\ntype=wifi\nautoconnect=true\n\n[wifi]\nmode=infrastructure\nssid=%s\n\n[wifi-security]\nkey-mgmt=wpa-psk\npsk=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
            "$kf_ssid" "$kf_psk" >"$nm_file"
    )
    PERMS+=('["/etc/NetworkManager/system-connections"]="0:0:700"'
        '["/etc/NetworkManager/system-connections/serverstick-wifi.nmconnection"]="0:0:600"')
    echo "wifi profile: /etc/NetworkManager/system-connections/serverstick-wifi.nmconnection"
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
