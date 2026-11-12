# ServerStick

A custom Arch Linux live ISO (archiso, based on `releng`) that turns any x86-64 machine into a headless
processing node. It boots on BIOS and UEFI (Secure Boot off), copies itself to RAM, joins your Tailscale
tailnet on its own and accepts Tailscale SSH. After boot you can pull the USB stick out. The machine's
own disks are never mounted, formatted or auto-activated.

## What's in the image

- releng base plus everything in `packages.txt` (tailscale, NVIDIA driver, monitoring, shell tools),
  and anything in `EXTRA_PACKAGES`.
- All boot entries (systemd-boot, syslinux, and GRUB if present) get
  `copytoram=y cow_spacesize=$COW_SPACESIZE systemd.gpt_auto=0 systemd.swap=0` (default `50%`).
- NetworkManager for wired DHCP (or a fixed `STATIC_IP`) and optional Wi-Fi, `NetworkManager-wait-online` behind
  `network-online.target`, systemd-timesyncd, and (with `NET_FALLBACK=1`) a network fallback, see
  [Networks without DHCP](#networks-without-dhcp).
- `tailscaled.service` plus `tailscale-autojoin.service`, a oneshot that runs `/usr/local/bin/serverstick-autojoin.lua`:
  1. waits for the tailscaled socket,
  2. waits until `controlplane.tailscale.com` resolves (up to 300 s) and briefly for clock sync,
  3. runs `tailscale up --auth-key=file:/etc/tailscale/authkey --ssh --hostname=$TS_HOSTNAME`
     up to 8 times with backoff (5 s, 10 s, 20 s, ... up to 60 s),
  4. logs every step to the journal. If all attempts fail, systemd restarts the unit every 30 s, forever.
- Changes from releng: OpenSSH `sshd` is **disabled** (only Tailscale SSH works), **cloud-init is disabled**,
  and LVM and RAID auto-activation are masked (`/etc/udev/rules.d/69-dm-lvm.rules`, `64-md-raid-assembly.rules`).
- No console autologin: log in as `root` with `ROOT_PASSWORD` from `.env`. Each console login prints a
  status banner (`serverstick-status.lua`). If `ROOT_PASSWORD` is empty, root has no password.

**RAM:** two things use memory beyond your workloads:

1. **The system image** (`copytoram=y`). It is copied into RAM at boot and costs its full size the whole
   time: about 1.5 GB with the default packages. Large `EXTRA_PACKAGES` such as `cuda` add several GB.
   You can only shrink it by installing less.
2. **Writable space** (`cow_spacesize`, set with `COW_SPACESIZE` in `.env`). Everything written at runtime
   (packages installed after boot, files, logs) lives here. It accepts a percentage of RAM or a size such as
   `8G`. It is a **limit, not a reservation**: memory is only used as data is written, and when it's
   full, writes fail with "No space left on device".

`/tmp` is a separate RAM filesystem with its own default limit of 50% of RAM. These are limits, not
reservations, so filling writable space and `/tmp` at the same time can still run the machine out of memory.
Check usage with `df -h /run/archiso/cowspace /tmp` and `free -h`.

**GPU:** `nvidia-open` supports Turing and newer (GTX 16xx / RTX 20xx and up).

## Layout

| Path | Purpose |
|---|---|
| `overlay/airootfs/` | Static files copied over releng's airootfs (units, scripts, banner, udev masks, service symlinks) |
| `serverstick.lua` | The command line: `build`, `verify`, `flash`, `test-qemu` (Lua) |
| `tools/*.lua` | Its modules: `build`, `verify`, `flash`, `qemu`, plus shared `config` (.env) and `util` |
| `packages.txt` | Packages added on top of releng |
| `.env` | Your config and secrets (gitignored) |
| `build/`, `work/`, `out/` | Generated profile, mkarchiso scratch space, finished ISO (all gitignored) |

Files generated at build time (never tracked): `/etc/hostname`, `/etc/shadow` (root password hash),
`/etc/tailscale/authkey` (0600), `/etc/tailscale/autojoin.env`, `/etc/serverstick/network.conf`, and the
NetworkManager profiles (0600): `serverstick-wifi` if Wi-Fi is set, `serverstick-static` + `serverstick-dhcp`
if `STATIC_IP` is set.

The tooling is plain Lua (5.1-5.4 or LuaJIT, no extra modules). It calls the same system tools as before:
archiso (`mkarchiso`, `unsquashfs`, `xorriso`, `mtools`, `bsdtar`), util-linux, `git`, `openssl`, and QEMU
for tests. Install the interpreter with `sudo pacman -S lua` if you don't have one.

## 1. Create the auth key

Tailscale admin console → **Settings → Keys → Generate auth key**:

- **Reusable**: on. The same ISO joins again on every boot and on every machine.
- **Ephemeral**: on. The system runs from RAM and starts with fresh state on every boot, so old nodes clean
  themselves up once they go offline.
- **Pre-approved**: on, if device approval is enabled on your tailnet. Otherwise the node waits for approval
  and never shows up as connected.
- **Expiration**: up to 90 days. Rebuild the ISO with a new key before it expires.

**Untagged key:** works with the default tailnet policy. Its default `ssh` rule allows your own devices to
reach root in `check` mode, so you may be asked to re-authenticate in the browser now and then.

**Tagged key** (for example `tag:stickserver`): the policy file needs a tag owner and an SSH rule. Without the
`tagOwners` entry, `tailscale up` fails. Without the `ssh` entry, SSH is refused.

```jsonc
"tagOwners": {
  "tag:stickserver": ["autogroup:admin"]
},
"ssh": [
  {
    "action": "accept",                // or "check"
    "src":    ["autogroup:member"],
    "dst":    ["tag:stickserver"],
    "users":  ["root"]
  }
]
```

Also make sure your `acls`/`grants` let your devices reach `tag:stickserver` (the default allow-all does).

## 2. Configure and build

Requires an Arch-based host. The repo must live on a Linux filesystem (ext4/btrfs), not exFAT or NTFS,
because the overlay contains symlinks.

```bash
cp .env.example .env
```

Edit `.env`:

```ini
TS_AUTHKEY=tskey-auth-...      # required
TS_HOSTNAME=stickserver        # default stickserver
ROOT_PASSWORD=...              # console login password (empty = no password)
EXTRA_PACKAGES="cuda"          # optional, space-separated
COW_SPACESIZE=50%              # optional: RAM limit for runtime writes, e.g. 75% or 8G
WIFI_SSID=                     # optional, set both or neither
WIFI_PASSWORD=
STATIC_IP=                     # optional fixed address a.b.c.d/nn for networks without DHCP
STATIC_GATEWAY=                #   its gateway (empty: found at boot by the gateway scan)
STATIC_DNS=                    #   DNS servers (default: gateway, 1.1.1.1, 9.9.9.9)
NET_FALLBACK=1                 # optional: static -> DHCP -> gateway scan fallback
NET_FALLBACK_WAIT=45           # optional: seconds to wait for DHCP before scanning
```

`.env` holds your auth key and password; keep it private (`chmod 600 .env`).

```bash
./serverstick.lua build
```

Run it as your normal user (it asks for sudo once) or as root / with `sudo`; outputs always end up owned by
you. It installs `archiso` if it's missing, copies a fresh `/usr/share/archiso/configs/releng` into
`build/profile`, applies `overlay/`, renders the templated files (hostname, auth key, root password hash,
Wi-Fi), adds the packages, patches the boot entries, runs `mkarchiso -v -w work -o out build/profile`,
deletes `work/`, and runs `./serverstick.lua verify`. It stops early if `.env` has a missing or invalid value.

Result: `out/serverstick-YYYY.MM.DD-x86_64.iso`.

**The ISO contains your auth key.** Treat the ISO and the stick like a password. Revoke the key
in the admin console if a stick gets lost.

Optional boot test (the VM really joins your tailnet if the key is valid):

```bash
./serverstick.lua test-qemu serial
```

`./serverstick.lua test-qemu bios` and `./serverstick.lua test-qemu uefi` boot through the real menus, log in on tty1
with `ROOT_PASSWORD`, and save a screenshot of the banner to `build/qemu/`.

## 3. Write the USB stick

This erases the whole stick.

- **Linux, with the helper script:**

  ```bash
  ./serverstick.lua flash
  ```

  It lists USB/removable drives with their size, model, labels and mount points. The disk your system
  runs from is never listed. You pick a drive by number and confirm by typing its device name (e.g. `sdb`).
  It then unmounts the drive, writes the newest `out/serverstick-*.iso` with `dd`, and compares the
  written data with the ISO. `./serverstick.lua flash --all` also lists internal disks, and
  `./serverstick.lua flash path/to.iso` writes a specific ISO.
- **Linux, by hand:** find the stick with `lsblk`, then run (with your device instead of `/dev/sdX`):

  ```bash
  sudo dd if=out/serverstick-*.iso of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress
  ```
- **Windows, Rufus:** select the ISO and click Start. When Rufus asks, choose
  **"Write in DD Image mode"**, not ISO mode. ISO mode rewrites the boot setup and can break the boot entries.
- **Windows/macOS, balenaEtcher:** Flash from file → select the stick → Flash. It always writes a raw copy.

## 4. Boot and connect

Boot the target machine from the stick. Set Secure Boot off; BIOS/CSM or UEFI both work. The menu boots the
first entry automatically after 15 s. Once the boot menu has passed and the system is up, you can remove
the stick.

After 30-90 s the machine shows up in the admin console as `stickserver`, or whatever `TS_HOSTNAME` you set:

```bash
ssh root@stickserver
```

or `tailscale ssh root@stickserver`. With MagicDNS off, use the node's `100.x.y.z` address.
If a previous boot's ephemeral node is still listed, the new one may come up as `stickserver-1` until the old
one expires.

## Troubleshooting (console banner)

Plug in a monitor and log in as `root` (password: `ROOT_PASSWORD`). The banner prints at login; run
`serverstick-status.lua` to refresh it.
Follow live with `journalctl -fu tailscale-autojoin`. All scripts on the stick are Lua and named
`serverstick-*.lua` in `/usr/local/bin` (tab-complete `serverstick-`); shared code is in `/usr/local/lib/serverstick/`.

| Banner section | What to look for |
|---|---|
| **IP addresses** | No `UP` interface with an IPv4 address → no DHCP. "IPv4 but no internet" → wrong gateway. See [Networks without DHCP](#networks-without-dhcp). Wi-Fi: `nmcli device`, `nmcli connection` |
| **Services** | `tailscaled` not `active` → `journalctl -u tailscaled`. `tailscale-autojoin` is `activating` while it waits/retries, `active` once joined, `failed`/`activating` again while it restarts every 30 s |
| **clock synced** | `no` and the date is far off → TLS errors. Check that NTP (UDP 123) can get out |
| **tailscale status** | `Logged out` / `NeedsLogin` → the join hasn't succeeded yet, see the journal lines. Hostname listed with a 100.x IP → joined |
| **journal (last 20)** | Each run logs `step 0/4` … `step 4/4`. Where it stops tells you which stage failed (table below) |

| Last journal message | Meaning / fix |
|---|---|
| `auth key file ... missing` / `does not start with 'tskey-'` | Rebuild with a correct `TS_AUTHKEY` |
| `tailscaled socket did not appear` | tailscaled crashed: `journalctl -u tailscaled -b` |
| `still waiting for network` / `cannot resolve controlplane.tailscale.com` | No route or DNS. The lines after it show IPs, routes and DNS servers. On captive or filtered networks, Tailscale can't reach its control server |
| `clock NOT synchronized` | Usually harmless; if `tailscale up` then shows x509/certificate errors, fix the time (`timedatectl`) |
| `tailscale up failed` + `invalid key` / `expired` | Key revoked, expired, or single-use and already used → make a new **reusable** key and rebuild |
| `tailscale up failed` + `tags` / `tagOwners` | Tagged key without `tagOwners` in the policy (see above) |
| Joined, but node missing or shows "Needs approval" in the admin page | Device approval is on and the key wasn't pre-approved → approve it, or use a pre-approved key |
| Joined, but `ssh` is refused | Tailnet policy `ssh` rules don't cover this node (needed for tagged nodes, see above) |
| `step 4/4: joined` | Working. Connect with `ssh root@<hostname>` |

### Networks without DHCP

Offices and labs often give each machine a fixed IP. Then the stick gets no IPv4 address.

**What the stick does at boot** (`netfind-fallback.service`, `NET_FALLBACK=1`; log: `journalctl -u netfind-fallback -b`):

1. With `STATIC_IP` set: use it (profile `serverstick-static`). If the internet answers, done. If not, drop it
   for this boot and try DHCP for 45 s.
2. Wait `NET_FALLBACK_WAIT` seconds (default 45) for DHCP, listening to the wire meanwhile.
3. Still nothing: test the gateway candidates it heard and apply the first one that **actually reaches the
   internet** (profile `netfind-<port>`, address `STATIC_IP` if set, else a free one). Nothing works →
   keep `STATIC_IP`, retry every 60 s.
4. Then it keeps watching. If the box loses IPv4 on every port (cable moved to another network), it starts
   over. A scanned gateway lasts until the link changes, so a network with DHCP always gets the first try.

With `.env` left empty, a network without DHCP is online about a minute after boot, with no settings.
`netfind-fallback` shows `active` in the banner for the whole uptime: that is the watcher.

**Gateway scan by hand:** `serverstick-gwscan.lua` listens to the wire (no IP needed), lists every address that
could be the router (`STATIC_GATEWAY`, addresses other machines keep asking for, `.1`/`.254` of each subnet
seen, all other hosts), then routes 1.1.1.1, 8.8.8.8, ... through each one in turn and tries TCP 443 / ping.
It only adds temporary test routes and removes them; it changes nothing else unless you pass `--apply`.

```bash
serverstick-gwscan.lua                          # scan every wired port
serverstick-gwscan.lua -i eno1 -a 192.168.163.250/24 -t 30   # test from a chosen address
serverstick-gwscan.lua --apply                  # configure the first working gateway
serverstick-netfind.lua --undo                  # remove profiles made by --apply
```

Each candidate is shown as `INTERNET OK`, `on the wire, no internet` (a printer, server, PC, ...) or
`no ARP answer`. Put the working one in `.env` as `STATIC_GATEWAY` (with the machine's address as
`STATIC_IP`) and rebuild, so the stick comes up right away next time.

Nothing reaches the internet, not even with the right address: the switch port may only allow
registered machines (MAC filtering / 802.1X) or outbound traffic may need a proxy. Ask the network admin.
