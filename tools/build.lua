-- serverstick build: assemble the archiso profile from releng + overlay + .env, run mkarchiso, verify.

local util = require("util")
local config = require("config")
local q, die, step, say = util.q, util.die, util.step, util.say

local RELENG = "/usr/share/archiso/configs/releng"

-- Pre-installed into /root/.tmux/plugins (the ISO has no use for prefix+I at runtime).
local TMUX_PLUGINS = {
  "tmux-plugins/tpm", "tmux-plugins/tmux-sensible", "sunaku/tmux-navigate",
  "shivamashtikar/tmux-onedark-theme", "sainnhe/tmux-fzf", "shivamashtikar/tmux-tiling-revamped",
  "tmux-plugins/tmux-copycat", "tmux-plugins/tmux-open",
}

-- Units from releng that this image must not start.
local REMOVE_FROM_RELENG = {
  -- sshd: only Tailscale SSH reaches this box.
  "etc/systemd/system/multi-user.target.wants/sshd.service",
  -- cloud-init: never read config from local disks.
  "etc/systemd/system/cloud-init.target.wants",
  -- releng still enables hv_fcopy_daemon.service, which the hyperv package no longer ships.
  "etc/systemd/system/multi-user.target.wants/hv_fcopy_daemon.service",
  -- NetworkManager (enabled by the overlay) replaces systemd-networkd + iwd.
  "etc/systemd/system/multi-user.target.wants/systemd-networkd.service",
  "etc/systemd/system/sockets.target.wants/systemd-networkd.socket",
  "etc/systemd/system/network-online.target.wants/systemd-networkd-wait-online.service",
  "etc/systemd/system/dbus-org.freedesktop.network1.service",
  "etc/systemd/system/multi-user.target.wants/iwd.service",
  "etc/systemd/network",
  "etc/systemd/system/systemd-networkd-wait-online.service.d",
  -- No console autologin: tty1 asks for the root password like every other console.
  "etc/systemd/system/getty@tty1.service.d",
}

-- Masked (linked to /dev/null) so they can't start at all. systemd-networkd is otherwise
-- socket-activated at boot, fights NetworkManager for the NICs, and its wait-online
-- times out after 2 minutes, delaying network-online.target and the tailnet join.
local MASK = {
  "systemd-networkd.service", "systemd-networkd.socket", "systemd-networkd-varlink.socket",
  "systemd-networkd-varlink-metrics.socket", "systemd-networkd-resolve-hook.socket",
  "systemd-networkd-wait-online.service",
}

-- profiledef.sh file_permissions entries: path -> "uid:gid:mode".
local function permissions_block(perms)
  local lines = { "", "# ServerStick", "file_permissions+=(" }
  for _, p in ipairs(perms) do
    lines[#lines + 1] = string.format('  [%q]="%s"', p[1], p[2])
  end
  lines[#lines + 1] = ")"
  return table.concat(lines, "\n") .. "\n"
end

-- NetworkManager keyfile value for an SSID: plain if simple, else a byte list.
local function keyfile_ssid(ssid)
  if ssid:match("^[%w_.-][%w _.-]*$") then return ssid end
  local bytes = {}
  for i = 1, #ssid do bytes[i] = tostring(ssid:byte(i)) end
  return table.concat(bytes, ";") .. ";"
end

-- Escape a passphrase for GKeyFile (backslash, tab, leading space).
local function keyfile_escape(s)
  s = s:gsub("\\", "\\\\"):gsub("\t", "\\t")
  if s:sub(1, 1) == " " then s = "\\s" .. s:sub(2) end
  return s
end

local function wifi_keyfile(env)
  return table.concat({
    "[connection]", "id=serverstick-wifi", "type=wifi", "autoconnect=true", "",
    "[wifi]", "mode=infrastructure", "ssid=" .. keyfile_ssid(env.WIFI_SSID), "",
    "[wifi-security]", "key-mgmt=wpa-psk", "psk=" .. keyfile_escape(env.WIFI_PASSWORD), "",
    "[ipv4]", "method=auto", "",
    "[ipv6]", "method=auto", "",
  }, "\n")
end

-- SHA-512 crypt hash of the root password; the plain text goes to openssl on stdin, never argv.
local function hash_password(password)
  local tmp = util.capture("mktemp")
  util.must("chmod 600 " .. q(tmp))
  util.write(tmp, password)
  local hash, ok = util.capture("openssl passwd -6 -stdin < " .. q(tmp))
  util.run("rm -f " .. q(tmp))
  if not ok or not hash:match("^%$6%$") then die("openssl passwd -6 failed") end
  return hash
end

-- Rewrite every line matching `pattern` in a file with fn(line).
local function edit_lines(path, pattern, fn)
  local out, changed = {}, 0
  local text = util.read(path) or die("cannot read " .. path)
  if text:sub(-1) ~= "\n" then text = text .. "\n" end
  for line in text:gmatch("([^\n]*)\n") do
    local new = line
    if line:find(pattern) then
      new = fn(line)
      if new ~= line then changed = changed + 1 end
    end
    out[#out + 1] = new
  end
  util.write(path, table.concat(out, "\n") .. "\n")
  return changed
end

return function(root, args)
  local profile = root .. "/build/profile"
  local work = root .. "/work"
  local out = root .. "/out"
  local A = profile .. "/airootfs"

  ------------------------------------------------------------ config
  step("Reading .env")
  local env = config.load(root, true)
  config.validate(env)
  local packages = config.packages(root)
  local boot_params = "copytoram=y cow_spacesize=" .. env.COW_SPACESIZE .. " systemd.gpt_auto=0 systemd.swap=0"
  say(string.format("hostname=%s  extra packages=%s  wifi=%s  cow_spacesize=%s  net_fallback=%s  root password=%s",
    env.TS_HOSTNAME, #env.EXTRA > 0 and table.concat(env.EXTRA, " ") or "none",
    env.WIFI_SSID ~= "" and env.WIFI_SSID or "off", env.COW_SPACESIZE, env.NET_FALLBACK,
    env.ROOT_PASSWORD ~= "" and "set" or "EMPTY (console login without password)"))

  -- The overlay holds tracked symlinks; they are lost on exFAT/NTFS checkouts.
  if not util.test("-L", root .. "/overlay/airootfs/etc/systemd/system/multi-user.target.wants/tailscaled.service") then
    die("overlay symlinks are missing. Keep the repo on a Linux filesystem (ext4/btrfs), not exFAT/NTFS.")
  end

  ------------------------------------------------------------ host tools
  step("Checking host tools")
  for _, tool in ipairs({ "git", "openssl" }) do
    if not util.have(tool) then die(tool .. " is required") end
  end
  if not (util.have("mkarchiso") and util.have("unsquashfs") and util.have("xorriso")) then
    say("Installing archiso")
    util.must(util.priv("pacman -S --needed --noconfirm archiso"), "could not install archiso")
  end
  if not util.test("-d", RELENG) then die(RELENG .. " not found") end
  local stop_keepalive = util.sudo_keepalive()

  local ok, err = pcall(function()
    ------------------------------------------------------------ profile
    step("Assembling profile in build/profile")
    util.wipe(profile, true)
    util.mkdir(root .. "/build")
    util.must("cp -a " .. q(RELENG) .. " " .. q(profile), "cannot copy releng")
    util.must("cp -a " .. q(root .. "/overlay/airootfs") .. "/. " .. q(A .. "/"), "cannot copy overlay")

    for _, rel in ipairs(REMOVE_FROM_RELENG) do
      util.must("rm -rf " .. q(A .. "/" .. rel))
    end
    for _, unit in ipairs(MASK) do
      util.must("ln -sfn /dev/null " .. q(A .. "/etc/systemd/system/" .. unit))
    end
    if env.NET_FALLBACK == "1" then
      util.must("ln -sfn ../netfind-fallback.service "
        .. q(A .. "/etc/systemd/system/multi-user.target.wants/netfind-fallback.service"))
    end

    step("Fetching tmux plugins")
    for _, repo in ipairs(TMUX_PLUGINS) do
      local dest = A .. "/root/.tmux/plugins/" .. repo:match("/(.+)$")
      util.must("git clone --quiet --depth 1 " .. q("https://github.com/" .. repo) .. " " .. q(dest),
        "could not clone https://github.com/" .. repo)
      say("  " .. repo)
    end

    step("Rendering templated files")
    util.write(A .. "/etc/hostname", env.TS_HOSTNAME .. "\n")
    util.mkdir(A .. "/etc/tailscale", "700")
    util.write(A .. "/etc/tailscale/authkey", env.TS_AUTHKEY)
    util.must("chmod 600 " .. q(A .. "/etc/tailscale/authkey"))
    util.write(A .. "/etc/tailscale/autojoin.env", "TS_HOSTNAME=" .. env.TS_HOSTNAME .. "\n")

    -- Root password: only the hash goes into the image. Empty means no password (releng default).
    local hash = env.ROOT_PASSWORD ~= "" and hash_password(env.ROOT_PASSWORD) or ""
    util.write(A .. "/etc/shadow", "root:" .. hash .. ":14871::::::\n")
    say("root password: " .. (hash ~= "" and "set (SHA-512 hash in /etc/shadow)" or "empty"))

    local perms = {
      { "/etc/tailscale", "0:0:700" },
      { "/etc/tailscale/authkey", "0:0:600" },
      { "/usr/local/bin/tailscale-autojoin", "0:0:755" },
      { "/usr/local/bin/serverstick-status", "0:0:755" },
      { "/usr/local/bin/netfind", "0:0:755" },
    }
    -- mkarchiso copies airootfs without file modes, so every executable in the plugins needs an entry.
    for f in util.lines_of("find " .. q(A .. "/root/.tmux/plugins") .. " -type f -perm -u+x -not -path '*/.git/*'") do
      perms[#perms + 1] = { f:sub(#A + 1), "0:0:755" }
    end

    if env.WIFI_SSID ~= "" then
      local dir = A .. "/etc/NetworkManager/system-connections"
      util.mkdir(dir, "700")
      util.write(dir .. "/serverstick-wifi.nmconnection", wifi_keyfile(env))
      util.must("chmod 600 " .. q(dir .. "/serverstick-wifi.nmconnection"))
      perms[#perms + 1] = { "/etc/NetworkManager/system-connections", "0:0:700" }
      perms[#perms + 1] = { "/etc/NetworkManager/system-connections/serverstick-wifi.nmconnection", "0:0:600" }
      say("wifi profile: /etc/NetworkManager/system-connections/serverstick-wifi.nmconnection")
    end

    step("Patching profiledef.sh")
    local pdef = profile .. "/profiledef.sh"
    edit_lines(pdef, "^iso_name=", function() return 'iso_name="serverstick"' end)
    edit_lines(pdef, "^iso_application=", function() return 'iso_application="ServerStick headless Tailscale node"' end)
    util.append(pdef, permissions_block(perms))

    step("Adding packages")
    local list_path = profile .. "/packages.x86_64"
    local seen, merged = {}, {}
    local function add(name)
      if name ~= "" and not seen[name] then seen[name] = true; merged[#merged + 1] = name end
    end
    for line in util.read(list_path):gmatch("[^\n]+") do add(line:match("^%s*(.-)%s*$")) end
    for _, p in ipairs(packages) do add(p) end
    for _, p in ipairs(env.EXTRA) do add(p) end
    util.write(list_path, table.concat(merged, "\n") .. "\n")
    say(string.format("  %d packages (%d from packages.txt, %d extra)", #merged, #packages, #env.EXTRA))

    step("Patching boot entries: " .. boot_params)
    local files = {}
    for f in util.lines_of("grep -rl 'archisobasedir=' " .. q(profile .. "/efiboot") .. " "
        .. q(profile .. "/syslinux") .. " " .. q(profile .. "/grub") .. " 2>/dev/null") do
      files[#files + 1] = f
    end
    if #files == 0 then die("no boot entries found in the releng profile") end
    for _, f in ipairs(files) do
      local n = edit_lines(f, "archisobasedir=", function(line)
        if line:find("copytoram=", 1, true) then return line end
        return (line:gsub("%s*$", "")) .. " " .. boot_params
      end)
      say(string.format("  %s: %d entr%s", f:sub(#profile + 2), n, n == 1 and "y" or "ies"))
    end

    ------------------------------------------------------------ build
    step("Running mkarchiso")
    util.wipe(work, true)
    util.mkdir(out)
    util.must(util.priv("mkarchiso -v -w " .. q(work) .. " -o " .. q(out) .. " " .. q(profile)), "mkarchiso failed")

  end)

  -- Also after a failure: work/ holds a copy of the auth key, and outputs belong to the
  -- invoking user even when run with sudo.
  step("Cleaning up")
  util.wipe(work, true)
  util.run(util.priv("chown -R " .. util.owner() .. " " .. q(out) .. " " .. q(root .. "/build")) .. " 2>/dev/null")
  stop_keepalive()
  if not ok then error(err, 0) end

  local iso = util.latest_iso(root)
  if not iso then die("mkarchiso finished but no ISO is in out/") end
  say("ISO: " .. iso .. " (" .. util.human(util.size(iso)) .. ")")

  step("Verifying")
  return require("verify")(root, { iso })
end
