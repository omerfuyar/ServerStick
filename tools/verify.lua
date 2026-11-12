-- serverstick verify: check a built ISO without booting it.

local util = require("util")
local config = require("config")
local q, say = util.q, util.say

---------------------------------------------------------------- squashfs listing

-- Parse `unsquashfs -lln`: "<mode> <uid>/<gid> <size> <date> <time> squashfs-root/<path>[ -> target]".
local function read_listing(path)
  local entries, count = {}, 0
  local f = io.open(path, "r")
  for line in f:lines() do
    local mode, uid, gid, rest = line:match("^(%S+)%s+(%d+)/(%d+)%s+%S+%s+%S+%s+%S+%s+squashfs%-root(/.*)$")
    if mode then
      local p, target = rest, nil
      if mode:sub(1, 1) == "l" then
        p, target = rest:match("^(.-) %-> (.*)$")
        p = p or rest
      end
      entries[p] = { mode = mode, uid = tonumber(uid), gid = tonumber(gid), target = target }
      count = count + 1
    end
  end
  f:close()
  return entries, count
end

-- Normalize "a/b/../c" style paths.
local function normpath(p)
  local parts = {}
  for seg in p:gmatch("[^/]+") do
    if seg == ".." then
      parts[#parts] = nil
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return "/" .. table.concat(parts, "/")
end

-- Follow symlinks inside the image; returns the final path or nil.
local function resolve(entries, p, depth)
  depth = depth or 0
  local e = entries[p]
  if depth > 20 or not e then return nil end
  if e.mode:sub(1, 1) ~= "l" then return p end
  local t = e.target
  if t:sub(1, 1) ~= "/" then t = p:match("^(.*)/[^/]*$") .. "/" .. t end
  return resolve(entries, normpath(t), depth + 1)
end

---------------------------------------------------------------- checks

return function(root, args)
  local iso = args[1] or util.latest_iso(root)
  if not iso or not util.test("-f", iso) then util.die("no ISO given and none found in out/") end
  for _, t in ipairs({ "bsdtar", "unsquashfs", "xorriso", "mcopy" }) do
    if not util.have(t) then util.die("'" .. t .. "' not found (install archiso)") end
  end

  -- Expected values: non-secret settings from .env, packages from packages.txt.
  local env = config.load(root, false)
  config.validate_static(env)
  local packages = config.packages(root)
  for _, p in ipairs(env.EXTRA) do packages[#packages + 1] = p end

  local T = root .. "/build/verify"
  util.wipe(T)
  util.mkdir(T .. "/iso")
  util.mkdir(T .. "/esp")
  util.mkdir(T .. "/bootimg")

  local fails = 0
  local function check(ok, msg)
    say((ok and "  PASS  " or "  FAIL  ") .. msg)
    if not ok then fails = fails + 1 end
  end

  -- Extraction runs in pcall so the secret copies are always removed afterwards.
  local ok, err = pcall(function()
    say("Verifying " .. iso)
    say("  extracting ISO filesystem")
    util.must("bsdtar -xf " .. q(iso) .. " -C " .. q(T .. "/iso") .. " --exclude 'arch/boot/*' --exclude 'boot/memtest86+/*'",
      "bsdtar failed")
    local sfs = util.capture("find " .. q(T .. "/iso") .. " -name airootfs.sfs"):match("^[^\n]+")
    if not sfs then util.die("airootfs.sfs not found in ISO") end

    say("  extracting EFI boot image(s)")
    util.run("xorriso -osirrox on -indev " .. q(iso) .. " -extract_boot_images " .. q(T .. "/bootimg/") .. " >/dev/null 2>&1")
    local i = 0
    for img in util.lines_of("find " .. q(T .. "/bootimg") .. " -type f") do
      if util.run("mcopy -s -n -i " .. q(img) .. " ::/loader " .. q(T .. "/esp/" .. i) .. " 2>/dev/null") then
        i = i + 1
      end
    end

    say("  listing squashfs")
    util.must("unsquashfs -lln " .. q(sfs) .. " > " .. q(T .. "/sfs.list"), "unsquashfs failed")
    util.run("unsquashfs -q -n -d " .. q(T .. "/root") .. " " .. q(sfs)
      .. " etc/tailscale etc/hostname etc/shadow etc/serverstick etc/NetworkManager/system-connections >/dev/null 2>&1")

    local entries, count = read_listing(T .. "/sfs.list")
    check(count > 1000, "squashfs listing parsed (" .. count .. " entries)")

    -- auth key
    local ak = entries["/etc/tailscale/authkey"]
    check(ak ~= nil, "/etc/tailscale/authkey exists")
    if ak then
      check(ak.mode == "-rw-------" and ak.uid == 0 and ak.gid == 0,
        "authkey mode/owner is -rw------- 0/0 (got " .. ak.mode .. " " .. ak.uid .. "/" .. ak.gid .. ")")
      local key = util.read(T .. "/root/etc/tailscale/authkey")
      check(key ~= nil and key:sub(1, 6) == "tskey-", "authkey content starts with tskey-")
    end
    check(entries["/etc/tailscale/autojoin.env"] ~= nil, "/etc/tailscale/autojoin.env exists")
    local hostname = (util.read(T .. "/root/etc/hostname") or ""):gsub("%s+$", "")
    check(hostname == env.TS_HOSTNAME, "/etc/hostname is '" .. env.TS_HOSTNAME .. "' (got '" .. hostname .. "')")

    -- root password and console login
    local shadow = util.read(T .. "/root/etc/shadow") or ""
    local root_hash = shadow:match("^root:([^:]*):") or shadow:match("\nroot:([^:]*):")
    if env.ROOT_PASSWORD ~= "" then
      check(root_hash ~= nil and root_hash:sub(1, 3) == "$6$", "root password set (SHA-512 hash in /etc/shadow)")
    else
      check(root_hash == "", "root password empty (ROOT_PASSWORD not set)")
    end
    local sh = entries["/etc/shadow"]
    check(sh ~= nil and sh.mode == "-r--------", "/etc/shadow mode is -r--------" .. (sh and " (got " .. sh.mode .. ")" or ""))
    check(entries["/etc/systemd/system/getty@tty1.service.d/autologin.conf"] == nil, "no console autologin on tty1")

    -- scripts, configs, binaries
    local files = {
      { "/usr/local/bin/serverstick-autojoin.lua", "-rwxr-xr-x" },
      { "/usr/local/bin/serverstick-status.lua", "-rwxr-xr-x" },
      { "/usr/local/bin/serverstick-netfind.lua", "-rwxr-xr-x" },
      { "/usr/local/bin/serverstick-gwscan.lua", "-rwxr-xr-x" },
      { "/usr/local/lib/serverstick/sys.lua" }, { "/usr/local/lib/serverstick/net.lua" },
      { "/usr/bin/lua" }, { "/usr/bin/tcpdump" }, { "/usr/bin/arping" }, { "/usr/bin/curl" },
      { "/etc/serverstick/network.conf" },
      { "/root/.tmux/plugins/tpm/tpm", "-rwxr-xr-x" },
      { "/root/.tmux.conf" }, { "/root/.config/fish/config.fish" },
      { "/etc/NetworkManager/conf.d/serverstick.conf" },
      { "/etc/systemd/system/tailscale-autojoin.service" },
      { "/etc/profile.d/zz-serverstick-banner.sh" },
      { "/usr/bin/tailscale" }, { "/usr/bin/tailscaled" }, { "/usr/bin/nvidia-smi" },
    }
    for _, f in ipairs(files) do
      local e = entries[f[1]]
      if f[2] then
        check(e ~= nil and e.mode == f[2], f[1] .. " exists with mode " .. f[2] .. (e and " (got " .. e.mode .. ")" or ""))
      else
        check(e ~= nil, f[1] .. " exists")
      end
    end

    -- every .wants/ symlink resolves
    local wants, broken = 0, {}
    for p, e in pairs(entries) do
      if p:match("^/etc/systemd/system/[^/]+%.wants/[^/]+$") then
        wants = wants + 1
        if e.mode:sub(1, 1) == "l" and not resolve(entries, p) then broken[#broken + 1] = p end
      end
    end
    table.sort(broken)
    check(#broken == 0, "all " .. wants .. " systemd .wants symlinks resolve"
      .. (#broken > 0 and "; broken: " .. table.concat(broken, ", ") or ""))

    local function enabled(unit, target)
      return entries["/etc/systemd/system/" .. target .. ".wants/" .. unit] ~= nil
    end
    local must_enable = {
      { "tailscaled.service", "multi-user.target" },
      { "tailscale-autojoin.service", "multi-user.target" },
      { "NetworkManager.service", "multi-user.target" },
      { "systemd-resolved.service", "multi-user.target" },
      { "NetworkManager-wait-online.service", "network-online.target" },
      { "systemd-timesyncd.service", "sysinit.target" },
    }
    for _, u in ipairs(must_enable) do
      check(enabled(u[1], u[2]), u[1] .. " enabled (" .. u[2] .. ".wants)")
    end
    if env.NET_FALLBACK == "1" then
      check(enabled("netfind-fallback.service", "multi-user.target"), "netfind-fallback.service enabled (NET_FALLBACK=1)")
    else
      check(not enabled("netfind-fallback.service", "multi-user.target"), "netfind-fallback.service NOT enabled (NET_FALLBACK=0)")
    end
    check(not enabled("sshd.service", "multi-user.target"), "sshd.service NOT enabled")
    for _, unit in ipairs({ "systemd-networkd.service", "iwd.service" }) do
      check(not enabled(unit, "multi-user.target"), unit .. " NOT enabled (NetworkManager owns networking)")
    end
    local unmasked = {}
    for _, unit in ipairs({ "systemd-networkd.service", "systemd-networkd.socket", "systemd-networkd-varlink.socket",
        "systemd-networkd-varlink-metrics.socket", "systemd-networkd-resolve-hook.socket",
        "systemd-networkd-wait-online.service" }) do
      local e = entries["/etc/systemd/system/" .. unit]
      if not (e and e.target == "/dev/null") then unmasked[#unmasked + 1] = unit end
    end
    check(#unmasked == 0, "systemd-networkd and its sockets/wait-online are masked"
      .. (#unmasked > 0 and "; not masked: " .. table.concat(unmasked, ", ") or ""))
    local cloud = false
    for p in pairs(entries) do
      if p:find("^/etc/systemd/system/cloud%-init%.target%.wants/") then cloud = true end
    end
    check(not cloud, "cloud-init NOT enabled")

    -- disk safeguards: masks must shadow real rules
    for _, rule in ipairs({ "69-dm-lvm.rules", "64-md-raid-assembly.rules" }) do
      check(entries["/etc/udev/rules.d/" .. rule] ~= nil and entries["/usr/lib/udev/rules.d/" .. rule] ~= nil,
        "udev rule " .. rule .. " masked in /etc and present in /usr/lib")
    end

    -- packages: /var/lib/pacman/local/<name>-<version>-<rel>
    local installed = {}
    for p in pairs(entries) do
      local dir = p:match("^/var/lib/pacman/local/([^/]+)$")
      local name = dir and dir:match("^(.+)%-[^-]+%-[^-]+$")
      if name then installed[name] = true end
    end
    for _, pkg in ipairs(packages) do
      check(installed[pkg] == true, "package " .. pkg .. " installed")
    end

    -- wifi
    local nm = entries["/etc/NetworkManager/system-connections/serverstick-wifi.nmconnection"]
    if env.WIFI_SSID ~= "" then
      check(nm ~= nil and nm.mode == "-rw-------", "wifi NetworkManager profile present with mode 0600")
    else
      check(nm == nil, "no wifi profile (wifi not configured)")
    end

    -- static IP
    local conf = util.read(T .. "/root/etc/serverstick/network.conf") or ""
    check(conf:find("\nSTATIC_IP=" .. env.STATIC_CIDR:gsub("%p", "%%%0") .. "\n") ~= nil,
      "network.conf has STATIC_IP=" .. env.STATIC_CIDR)
    check(conf:find("\nFALLBACK_WAIT=" .. env.NET_FALLBACK_WAIT .. "\n", 1, true) ~= nil,
      "network.conf has FALLBACK_WAIT=" .. env.NET_FALLBACK_WAIT)
    for _, name in ipairs({ "serverstick-static", "serverstick-dhcp" }) do
      local e = entries["/etc/NetworkManager/system-connections/" .. name .. ".nmconnection"]
      if env.STATIC_CIDR ~= "" then
        check(e ~= nil and e.mode == "-rw-------", name .. " NetworkManager profile present with mode 0600")
      else
        check(e == nil, "no " .. name .. " profile (STATIC_IP not set)")
      end
    end
    if env.STATIC_CIDR ~= "" then
      local kf = util.read(T .. "/root/etc/NetworkManager/system-connections/serverstick-static.nmconnection") or ""
      local want = "address1=" .. env.STATIC_CIDR .. (env.STATIC_GATEWAY ~= "" and ("," .. env.STATIC_GATEWAY) or "")
      check(kf:find("\n" .. want:gsub("%p", "%%%0") .. "\n") ~= nil, "static profile has " .. want)
    end

    -- boot entries (ISO tree + EFI system partition image)
    local counts, total, bad = { syslinux = 0, ["systemd-boot"] = 0, grub = 0, other = 0 }, 0, {}
    local want_cow = "cow_spacesize=" .. env.COW_SPACESIZE
    local find_cfg = "find " .. q(T .. "/iso") .. " " .. q(T .. "/esp") .. " -type f \\( -name '*.cfg' -o -name '*.conf' \\)"
    for path in util.lines_of(find_cfg) do
      local kind = path:find("/loader/", 1, true) and "systemd-boot"
        or path:find("syslinux", 1, true) and "syslinux"
        or path:find("grub", 1, true) and "grub" or "other"
      local n = 0
      for line in ((util.read(path) or "") .. "\n"):gmatch("([^\n]*)\n") do
        n = n + 1
        if line:find("archisobasedir=", 1, true) then
          counts[kind] = counts[kind] + 1
          total = total + 1
          local words = {}
          for w in line:gmatch("%S+") do words[w] = true end
          if not (words["copytoram=y"] and words[want_cow]) then
            bad[#bad + 1] = path:sub(#T + 2) .. ":" .. n
          end
        end
      end
    end
    check(counts.syslinux > 0, "syslinux (BIOS) boot entries found: " .. counts.syslinux)
    check(counts["systemd-boot"] > 0, "systemd-boot (UEFI) boot entries found: " .. counts["systemd-boot"])
    if counts.grub > 0 then say("  info  grub boot entries found: " .. counts.grub) end
    check(#bad == 0, "all " .. total .. " boot entries contain copytoram=y " .. want_cow
      .. (#bad > 0 and "; missing in " .. table.concat(bad, ", ") or ""))
  end)

  -- Don't leave the extracted secrets or the big squashfs copy around.
  util.wipe(T .. "/root")
  util.wipe(T .. "/iso")
  if util.is_root() then util.run("chown -R " .. util.owner() .. " " .. q(T)) end
  if not ok then error(err, 0) end

  say("")
  if fails > 0 then
    say("VERIFY FAILED: " .. fails .. " check(s) failed")
    return 1
  end
  say("VERIFY OK")
  return 0
end
