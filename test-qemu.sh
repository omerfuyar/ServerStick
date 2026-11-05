#!/usr/bin/env bash
# Headless QEMU boot test for a built ServerStick ISO.
#
#   ./test-qemu.sh [serial|bios|uefi] [iso]
#
#   serial (default)  boots the ISO's kernel with the same params as the BIOS
#                     menu entry plus console=ttyS0, streams the journal to the
#                     serial log, and checks tailscaled + tailscale-autojoin.
#   bios | uefi       boots through the real syslinux / systemd-boot menu and
#                     saves a screenshot of tty1 (the status banner).
#
# Env: QEMU_MEM (default 4G), QEMU_TIMEOUT seconds (default 300 serial, 150 bios/uefi).
# With a real key in .env the VM really joins your tailnet (as an ephemeral node).
set -euo pipefail

ROOT="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
MODE="${1:-serial}"
ISO="${2:-$(ls -t "$ROOT"/out/serverstick-*.iso 2>/dev/null | head -n1 || true)}"
MEM="${QEMU_MEM:-4G}"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "ERROR: no ISO found in out/" >&2; exit 1; }
command -v qemu-system-x86_64 >/dev/null || { echo "ERROR: qemu-system-x86_64 not installed" >&2; exit 1; }

T="$ROOT/build/qemu"
mkdir -p "$T"
LOG="$T/$MODE-serial.log"
MON="$T/$MODE-monitor.sock"
rm -f "$LOG" "$MON"

ACCEL=(-machine q35 -smp 4 -m "$MEM")
[[ -w /dev/kvm ]] && ACCEL+=(-enable-kvm -cpu host)
COMMON=("${ACCEL[@]}" -nic user,model=virtio-net-pci -display none
        -serial "file:$LOG" -monitor "unix:$MON,server,nowait"
        -drive "file=$ISO,media=cdrom,readonly=on,if=none,id=cd" -device ide-cd,drive=cd -boot order=d)

monitor() {  # send one command to the QEMU monitor
    python3 -I -c '
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); time.sleep(0.3); s.recv(65536)
s.sendall((sys.argv[2] + "\n").encode()); time.sleep(1.5); s.close()' "$MON" "$1"
}

QEMU_PID=
cleanup() { [[ -n "$QEMU_PID" ]] && kill "$QEMU_PID" 2>/dev/null || true; }
trap cleanup EXIT

case "$MODE" in
serial)
    TIMEOUT="${QEMU_TIMEOUT:-300}"
    bsdtar -xf "$ISO" -C "$T" arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img boot/syslinux/archiso_sys-linux.cfg
    PARAMS="$(grep -m1 '^APPEND archisobasedir=' "$T/boot/syslinux/archiso_sys-linux.cfg" | sed 's/^APPEND //')"
    PARAMS="$PARAMS console=ttyS0,115200 systemd.journald.forward_to_console=1"
    echo "kernel params: $PARAMS"
    qemu-system-x86_64 "${COMMON[@]}" \
        -kernel "$T/arch/boot/x86_64/vmlinuz-linux" -initrd "$T/arch/boot/x86_64/initramfs-linux.img" \
        -append "$PARAMS" &
    QEMU_PID=$!
    echo "booting (serial log: $LOG, timeout ${TIMEOUT}s)"
    for ((s = 0; s < TIMEOUT; s += 5)); do
        sleep 5
        kill -0 "$QEMU_PID" 2>/dev/null || { echo "QEMU exited early"; break; }
        grep -qE 'tailscale-autojoin.*(step 4/4|giving up)' "$LOG" 2>/dev/null && { sleep 5; break; }
    done
    echo
    echo "---- autojoin journal lines ----"
    grep -a 'tailscale-autojoin' "$LOG" | tail -n 40 || true
    echo "--------------------------------"
    fails=0
    chk() { if grep -aqE "$2" "$LOG"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails + 1)); fi; }
    chk "copied to RAM (copytoram)"           'Copying rootfs image to RAM|copytoram'
    chk "tailscaled started"                  'Started .*[Tt]ailscale node agent|tailscaled.*(Program starting|logtail started)'
    chk "tailscale-autojoin started"          'tailscale-autojoin.*step 0/4'
    chk "autojoin saw tailscaled socket"      'tailscale-autojoin.*tailscaled is up'
    chk "autojoin got network/DNS"            'tailscale-autojoin.*controlplane.tailscale.com resolves'
    if grep -aq 'tailscale-autojoin.*step 4/4' "$LOG"; then echo "INFO  join succeeded"; else echo "INFO  join did not succeed (fine in a VM)"; fi
    exit "$fails"
    ;;
bios|uefi)
    TIMEOUT="${QEMU_TIMEOUT:-150}"
    FW=()
    if [[ "$MODE" == uefi ]]; then
        CODE="$(ls /usr/share/edk2/x64/OVMF_CODE.4m.fd /usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd 2>/dev/null | head -n1)"
        VARS="$(ls /usr/share/edk2/x64/OVMF_VARS.4m.fd /usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd 2>/dev/null | head -n1)"
        [[ -n "$CODE" && -n "$VARS" ]] || { echo "ERROR: OVMF firmware not found (pacman -S edk2-ovmf)" >&2; exit 1; }
        cp "$VARS" "$T/OVMF_VARS.fd"
        FW=(-drive "if=pflash,format=raw,readonly=on,file=$CODE" -drive "if=pflash,format=raw,file=$T/OVMF_VARS.fd")
    fi
    qemu-system-x86_64 "${COMMON[@]}" "${FW[@]}" -vga std &
    QEMU_PID=$!
    echo "booting $MODE through the real boot menu, screenshot in ${TIMEOUT}s"
    sleep "$TIMEOUT"
    kill -0 "$QEMU_PID" 2>/dev/null || { echo "ERROR: QEMU exited early" >&2; exit 1; }
    monitor "screendump $T/$MODE-tty1.png -f png"
    echo "screenshot: $T/$MODE-tty1.png"
    ;;
*)
    echo "usage: $0 [serial|bios|uefi] [iso]" >&2; exit 2 ;;
esac
