#!/usr/bin/env bash
# Short status overview. Shown at console login; run again any time.
b=$'\e[1m'; r=$'\e[0m'

echo "${b}== $(uname -n) | $(uname -r) | up $(uptime -p | sed 's/^up //')${r}"

echo "${b}== IP addresses${r}"
ip -br addr show | grep -v '^lo '
ip route show default | sed 's/^/  route: /'
if [[ -z "$(ip -4 addr show scope global | grep -v tailscale)" ]]; then
    echo "  ${b}No IPv4 address.${r} Find the gateway: netfind  (apply: netfind --apply)  or configure: nmtui"
fi

echo "${b}== Services${r}"
for u in NetworkManager NetworkManager-wait-online netfind-fallback systemd-timesyncd tailscaled tailscale-autojoin; do
    printf '  %-30s %s\n' "$u" "$(systemctl is-active "$u" 2>&1)"
done
printf '  %-30s %s\n' "clock synced" "$(timedatectl show -p NTPSynchronized --value 2>&1) ($(date -u '+%F %T UTC'))"
if lspci -d 10de: 2>/dev/null | grep -qiE 'vga|3d|display'; then
    nvidia-smi -L 2>&1 | sed 's/^/  /'
else
    echo "  no NVIDIA GPU detected"
fi

echo "${b}== tailscale status${r}"
tailscale status 2>&1 | head -n 15

echo "${b}== journalctl -u tailscale-autojoin (last 20)${r}"
journalctl -u tailscale-autojoin -n 20 --no-pager -o short --no-hostname 2>&1

echo "${b}Re-run: serverstick-status | follow: journalctl -fu tailscale-autojoin${r}"
