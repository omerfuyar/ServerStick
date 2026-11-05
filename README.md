# ServerStick

A custom Arch Linux live ISO (archiso, based on `releng`) that turns any x86-64 machine into a headless
processing node. It boots on BIOS and UEFI (Secure Boot off), copies itself to RAM, joins your Tailscale
tailnet on its own and accepts Tailscale SSH. After boot you can pull the USB stick out. The machine's
own disks are never mounted, formatted or auto-activated.

## What's in the image

- releng base plus `tailscale openssh nvidia-open nvidia-utils btop nvtop lm_sensors pciutils tmux git python`,
  and anything in `EXTRA_PACKAGES`.
- All boot entries (systemd-boot, syslinux, and GRUB if present) get
  `copytoram=y cow_spacesize=$COW_SPACESIZE systemd.gpt_auto=0 systemd.swap=0` (default `50%`).
- Wired DHCP (systemd-networkd), optional Wi-Fi (iwd), systemd-timesyncd, and
  `systemd-networkd-wait-online --any` behind `network-online.target`.
- `tailscaled.service` plus `tailscale-autojoin.service`, a oneshot that runs `/usr/local/bin/tailscale-autojoin`:
  1. waits for the tailscaled socket,
  2. waits until `controlplane.tailscale.com` resolves (up to 300 s) and briefly for clock sync,
  3. runs `tailscale up --auth-key=file:/etc/tailscale/authkey --ssh --hostname=$TS_HOSTNAME`
     up to 8 times with backoff (5 s, 10 s, 20 s, ... up to 60 s),
  4. logs every step to the journal. If all attempts fail, systemd restarts the unit every 30 s, forever.
- Changes from releng: OpenSSH `sshd` is **disabled** (only Tailscale SSH works), **cloud-init is disabled**,
  and LVM and RAID auto-activation are masked (`/etc/udev/rules.d/69-dm-lvm.rules`, `64-md-raid-assembly.rules`).
- tty1 logs in as root automatically and prints a status banner (`serverstick-status`).

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
| `build.sh` | One-command build |
| `verify.sh` | Checks the finished ISO without booting it (`build.sh` runs it automatically) |
| `test-qemu.sh` | Optional headless QEMU boot test |
| `flash.sh` | Writes the ISO to a USB drive you pick from a list, then checks the written data |
| `.env` | Your config and secrets (gitignored) |
| `build/`, `work/`, `out/` | Generated profile, mkarchiso scratch space, finished ISO (all gitignored) |

Files generated at build time (never tracked): `/etc/hostname`, `/etc/tailscale/authkey` (0600),
`/etc/tailscale/autojoin.env`, and `/var/lib/iwd/<ssid>.psk` (0600, only if Wi-Fi is set).

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
TS_HOSTNAME=stickserver            # default stickserver
EXTRA_PACKAGES="cuda"          # optional, space-separated
COW_SPACESIZE=50%              # optional: RAM limit for runtime writes, e.g. 75% or 8G
WIFI_SSID=                     # optional, set both or neither
WIFI_PASSWORD=
```

```bash
./build.sh
```

`build.sh` installs `archiso` if it's missing and asks for sudo once. It then copies a fresh
`/usr/share/archiso/configs/releng` into `build/profile`, applies `overlay/`, renders the templated
files, adds the packages, patches the boot entries, runs
`mkarchiso -v -w work -o out build/profile`, gives `out/` back to your user, deletes `work/`,
and runs `verify.sh`. It stops early if `TS_AUTHKEY` is missing or doesn't start with `tskey-`.

Result: `out/serverstick-YYYY.MM.DD-x86_64.iso`.

**The ISO contains your auth key.** Treat the ISO and the stick like a password. Revoke the key
in the admin console if a stick gets lost.

Optional boot test (the VM really joins your tailnet if the key is valid):

```bash
./test-qemu.sh serial
```

`./test-qemu.sh bios` and `./test-qemu.sh uefi` boot through the real menus and save a screenshot of the
tty1 banner to `build/qemu/`.

## 3. Write the USB stick

This erases the whole stick.

- **Linux, with the helper script:**

  ```bash
  ./flash.sh
  ```

  It lists USB/removable drives with their size, model, labels and mount points. The disk your system
  runs from is never listed. You pick a drive by number and confirm by typing its device name (e.g. `sdb`).
  The script then unmounts the drive, writes the newest `out/serverstick-*.iso` with `dd`, and compares the
  written data with the ISO. `./flash.sh --all` also lists internal disks, and `./flash.sh path/to.iso`
  writes a specific ISO.
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

Plug in a monitor. tty1 logs in as root and prints this banner; run `serverstick-status` to refresh it.
Follow live with `journalctl -fu tailscale-autojoin`.

| Banner section | What to look for |
|---|---|
| **IP addresses** | No `UP` interface with an IPv4 address → no DHCP. Check the cable, or Wi-Fi: `iwctl station wlan0 show`, `networkctl status` |
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
