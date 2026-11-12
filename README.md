# ServerStick

A custom Arch Linux live ISO that turns any x86-64 machine into a headless server on your Tailscale
tailnet. Boot it (BIOS or UEFI, Secure Boot off), and it copies itself to RAM, gets online on its own
(even without DHCP), joins the tailnet and accepts Tailscale SSH. The machine's disks are never touched.

## Quick start

1. **Make an auth key** in the Tailscale admin console → Settings → Keys: **reusable**, **ephemeral**,
   **pre-approved** (if device approval is on). It expires after at most 90 days; rebuild with a new one.
2. **Configure:** `cp .env.example .env`, set `TS_AUTHKEY` (and `ROOT_PASSWORD`), then `chmod 600 .env`.
3. **Build** (Arch-based host, repo on ext4/btrfs; asks for sudo once):
   ```bash
   ./serverstick.lua build
   ```
   Result: `out/serverstick-YYYY.MM.DD-x86_64.iso`. It is checked automatically (`./serverstick.lua verify`).
4. **Write the stick** (erases it; lists only removable drives, asks you to type the device name):
   ```bash
   ./serverstick.lua flash
   ```
   On Windows use Rufus in **DD image mode**, or balenaEtcher.
5. **Boot** the machine from the stick. After about a minute it shows up in the tailnet:
   ```bash
   ssh root@stickserver
   ```

**The ISO and the stick contain your auth key.** Treat them like a password; revoke the key if a stick is lost.

## Settings (`.env`)

| Setting | Default | Meaning |
|---|---|---|
| `TS_AUTHKEY` | required | Tailscale auth key |
| `TS_HOSTNAME` | `stickserver` | Tailnet name and hostname |
| `ROOT_PASSWORD` | empty | Console login password (only its hash goes into the ISO; empty = no password) |
| `EXTRA_PACKAGES` | empty | More Arch packages, space-separated (they live in RAM too) |
| `COW_SPACESIZE` | `50%` | RAM limit for files written at runtime: a percentage or a size like `8G` |
| `WIFI_SSID`, `WIFI_PASSWORD` | empty | Optional Wi-Fi (WPA-PSK) |
| `STATIC_IP`, `STATIC_GATEWAY`, `STATIC_DNS` | empty | Optional fixed address; not needed, see below |
| `NET_FALLBACK` | `1` | Find a gateway automatically when DHCP gives nothing |
| `NET_FALLBACK_WAIT` | `45` | Seconds to wait for DHCP before that |

Packages for every build are in `packages.txt`.

## Networks without DHCP

Nothing to configure. `netfind-fallback.service` waits `NET_FALLBACK_WAIT` seconds for DHCP while listening to
the network, then tests every machine it heard as a possible router and uses the first one that really
reaches the internet, with a free address. It keeps watching: if the cable moves to another network, it starts
over (DHCP first). `STATIC_IP` settings, if set, are tried first and dropped for that boot if they don't work.

On the stick, `serverstick-gwscan.lua` shows the same test by hand: each candidate is marked
`INTERNET OK`, `on the wire, no internet` (printer, PC, ...) or `no ARP answer`.

## On the stick

Log in on the console as `root`. The status banner shows addresses, services, GPU and the tailnet join log.

- `serverstick-help.lua`: every useful command, one line each
- `serverstick-status.lua`: the banner again
- `journalctl -u tailscale-autojoin -b`: the join log (`step 0/4` … `step 4/4: joined`)
- `journalctl -u netfind-fallback -b`: what the network fallback did

Everything runs from RAM: about 1.5 GB for the system, plus what you write (up to `COW_SPACESIZE`).
Installed packages and files are gone after a reboot. sshd is off (Tailscale SSH only), cloud-init is off,
and LVM/RAID auto-activation is masked. The NVIDIA driver (`nvidia-open`) needs a Turing or newer GPU.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Banner: "No IPv4 address" | No DHCP yet; the fallback needs `NET_FALLBACK_WAIT` + ~15 s. Check `journalctl -u netfind-fallback -b` or run `serverstick-gwscan.lua` |
| Banner: "IPv4 but no internet" | Wrong gateway: `serverstick-gwscan.lua` |
| Join log stops at `waiting for network` | No route or DNS, or a filtered network that blocks Tailscale |
| `tailscale up failed` + `invalid` / `expired` key | Make a new reusable key and rebuild |
| `tailscale up failed` + `tags` | Tagged key needs `tagOwners` (and an `ssh` rule) in the tailnet policy |
| Node shows "Needs approval" | Approve it, or use a pre-approved key |
| Comes up as `stickserver-1` | An older node with that name is still listed; it expires on its own |
| Joined only after you logged in on the console | Joining never waits for a login (tested in QEMU: joined with nobody logged in). On older ISOs, a network without DHCP stayed offline until it was fixed by hand after logging in. Current ISOs find the gateway themselves; if it still happens, send `journalctl -u netfind-fallback -u tailscale-autojoin -b` |

## Repo layout

| Path | Purpose |
|---|---|
| `serverstick.lua`, `tools/` | Host tool (Lua): `build`, `verify`, `flash`, `test-qemu serial\|bios\|uefi` |
| `overlay/airootfs/` | Files copied into the image: units, `serverstick-*.lua` scripts, shared code in `/usr/local/lib/serverstick/` |
| `packages.txt`, `.env` | Packages and settings |
| `build/`, `work/`, `out/` | Build output (gitignored) |

`./serverstick.lua test-qemu serial` boots the ISO in QEMU and checks that it joins (the VM really joins
your tailnet). Host requirements: Lua 5.1+, archiso, git, openssl, and QEMU for tests.
