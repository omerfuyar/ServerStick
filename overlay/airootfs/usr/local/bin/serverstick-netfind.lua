#!/usr/bin/env lua
-- Get this box online when DHCP gives nothing. Run by netfind-fallback.service with --fallback.

local USAGE = [[
Get this box online when DHCP gives nothing: find a gateway that really reaches the internet
(see serverstick-gwscan.lua) and configure it with NetworkManager.

  serverstick-netfind.lua                  scan ports with a link but no IPv4, show the result
  serverstick-netfind.lua -i eno1 -t 30    scan one port, listen for 30 s
  serverstick-netfind.lua --apply          scan, then configure the first wired port with a working gateway
  serverstick-netfind.lua --undo           delete the profiles --apply made
  serverstick-netfind.lua --fallback       boot mode (netfind-fallback.service), runs forever:

Boot mode:
  1. STATIC_IP set in .env: wait for the static profile, test the internet. Works -> online.
     Broken -> disable it for this boot and fall through to DHCP.
  2. Wait NET_FALLBACK_WAIT seconds (default 45, --wait overrides) for DHCP, listening to the
     wire meanwhile.
  3. Still no IPv4: test the gateway candidates heard on the wire (with STATIC_IP as the address
     if set) and apply one only if it reached the internet. Nothing works -> retry in 60 s.
  4. Online: watch. If every port loses IPv4 (cable moved, link lost), start again at 1.
     A gateway applied by the scan lasts until the link changes; then DHCP gets the first try.

Options: -i/--iface IF (repeatable)  -t/--time SECONDS (15)  --force  --wait SECONDS
         --static-wait SECONDS (30)
]]

local self = io.popen("readlink -f '" .. (arg and arg[0] or ""):gsub("'", "'\\''") .. "'"):read("*l") or ""
package.path = (self:match("^(.*)/[^/]*$") or ".") .. "/../lib/serverstick/?.lua;" .. package.path

local sys = require("sys")
local net = require("net")
local log, q, quiet, capture = sys.log, sys.q, sys.quiet, sys.capture

local opts = sys.parse_args(arg, {
  ["-i"] = { "iface", "list" }, ["--iface"] = { "iface", "list" },
  ["-t"] = { "time", "value" }, ["--time"] = { "time", "value" },
  ["--force"] = { "force", "flag" }, ["--apply"] = { "apply", "flag" }, ["--undo"] = { "undo", "flag" },
  ["--fallback"] = { "fallback", "flag" }, ["--wait"] = { "wait", "value" },
  ["--static-wait"] = { "static_wait", "value" },
}, USAGE)
local listen_s = tonumber(opts.time or 15)
local static_wait_s = tonumber(opts.static_wait or 30)

-- Wait for any global IPv4 (or the address `want`). Returns { ifname = {cidr...} } or nil.
local function wait_ipv4(seconds, want)
  local deadline = sys.now() + seconds
  while true do
    local have = net.global_ipv4()
    local found
    for name, addrs in pairs(have) do
      for _, a in ipairs(addrs) do
        if not want or a:match("^[^/]+") == want then
          found = found or {}
          found[name] = addrs
        end
      end
    end
    if found then return found end
    if sys.now() >= deadline then return nil end
    sys.sleep(2)
  end
end

local function describe(have)
  local parts = {}
  for name, addrs in pairs(have) do parts[#parts + 1] = name .. " " .. table.concat(addrs, " ") end
  return table.concat(parts, "; ")
end

local function static_enabled()
  if not net.has_profile(net.STATIC_PROFILE) then return false end
  return capture("nmcli -g connection.autoconnect connection show " .. q(net.STATIC_PROFILE)) == "yes"
end

local function static_device()
  local dev = capture("nmcli -g GENERAL.DEVICES connection show " .. q(net.STATIC_PROFILE) .. " 2>/dev/null")
  return dev ~= "" and dev or nil
end

local function set_static(enabled, dev)
  local ifarg = dev and (" ifname " .. q(dev)) or ""
  if enabled then
    quiet("nmcli connection modify " .. q(net.STATIC_PROFILE) .. " connection.autoconnect yes")
    quiet("nmcli --wait 0 connection up " .. q(net.STATIC_PROFILE) .. ifarg)
    log("static profile '" .. net.STATIC_PROFILE .. "' restored")
  else
    -- Only in RAM: the next boot tries the static settings again.
    quiet("nmcli connection modify " .. q(net.STATIC_PROFILE) .. " connection.autoconnect no")
    quiet("nmcli connection down " .. q(net.STATIC_PROFILE))
    if dev then quiet("nmcli --wait 0 connection up " .. q(net.DHCP_PROFILE) .. ifarg) end
    log("static profile disabled for this boot; trying DHCP" .. (dev and (" on " .. dev) or ""))
  end
end

local function scan_and_apply(ifaces, conf, wires)
  for _, i in ipairs(ifaces) do
    local res = net.scan(i, listen_s, conf, { stop_first = true, wire = wires and wires[i] })
    if res and res.best then
      local addr, gw, dns = net.config_for(res, conf)
      if net.apply(i, addr, gw, dns) then return true end
    end
  end
  return false
end

-- Wait for DHCP while listening on every wired port with a link. Returns (have, wires).
local function wait_listening(seconds)
  local caps = {}
  for _, i in ipairs(net.pick_ifaces(nil, false, true)) do caps[#caps + 1] = net.capture_start(i, seconds + 5) end
  local have = wait_ipv4(seconds)
  local wires = {}
  for _, c in ipairs(caps) do wires[c.ifname] = net.capture_finish(c) end
  return have, wires
end

-- One pass: static, then DHCP, then scan. True when online.
local function fallback_once(conf)
  local used_static, dev = false, nil

  if conf.static and static_enabled() then
    used_static = true
    local ip = net.n2ip(conf.static.ip)
    log("STATIC_IP " .. net.cidr(conf.static) .. " set: waiting up to " .. static_wait_s .. "s for it")
    if wait_ipv4(static_wait_s, ip) then
      dev = static_device()
      local inet = net.internet_ok()
      if inet then
        log("static config works (" .. net.cidr(conf.static) .. " via "
          .. (conf.STATIC_GATEWAY ~= "" and conf.STATIC_GATEWAY or "no gateway") .. "): internet OK, " .. inet)
        return true
      end
      log("static config is up on " .. (dev or "?") .. " but the internet is NOT reachable (gateway "
        .. (conf.STATIC_GATEWAY ~= "" and conf.STATIC_GATEWAY or "not set") .. ")")
    else
      log("static profile did not come up (cable? address already in use? see: journalctl -u NetworkManager)")
    end
    set_static(false, dev)
  end

  log("waiting up to " .. conf.wait .. "s for an IPv4 address from DHCP (listening to the wire meanwhile)")
  local have, wires = wait_listening(conf.wait)
  if have then
    log("IPv4 present: " .. describe(have))
    return true
  end

  log("no IPv4 after " .. conf.wait .. "s: testing gateway candidates")
  if scan_and_apply(net.pick_ifaces(nil, false, true), conf, wires) then return true end
  log("no gateway reached the internet. Details: serverstick-gwscan.lua")
  if used_static then set_static(true, dev) end
  net.ipv6_hint()
  return false
end

local function fallback()
  local conf = net.read_conf()
  if opts.wait then conf.wait = tonumber(opts.wait) end
  while true do
    if fallback_once(conf) then
      -- Online: watch until every port has lost IPv4, then start over.
      while net.has_ipv4() do sys.sleep(5) end
      log("no IPv4 on any port anymore (cable moved or link lost): starting over")
    else
      log("retrying in 60s")
      sys.sleep(60)
    end
  end
end

local function main()
  if not sys.is_root() then
    io.stderr:write("serverstick-netfind.lua needs root\n")
    return 1
  end
  if opts.undo then
    net.undo()
    return 0
  end
  if opts.fallback then
    fallback()
    return 0
  end

  local conf = net.read_conf()
  local ifaces = net.pick_ifaces(opts.iface, opts.force)
  if opts.apply then
    local wired = {}
    for _, i in ipairs(ifaces) do
      if not net.is_wireless(i) then wired[#wired + 1] = i end
    end
    if #wired == 0 then
      log("nothing to apply")
      return 1
    end
    return scan_and_apply(wired, conf) and 0 or 1
  end
  local found = false
  for _, i in ipairs(ifaces) do
    local res = net.scan(i, listen_s, conf, { stop_first = true })
    if res and res.best then
      found = true
      local addr, gw, dns = net.config_for(res, conf)
      log("[" .. i .. "] working config: " .. addr .. " via " .. gw .. ", dns " .. table.concat(dns, " "))
      if net.is_wireless(i) then
        log("[" .. i .. "] Wi-Fi: nmcli connection modify <name> ipv4.method manual ipv4.addresses " .. addr
          .. " ipv4.gateway " .. gw .. " ipv4.dns " .. table.concat(dns, ","))
      else
        log("[" .. i .. "] apply:   serverstick-netfind.lua --apply -i " .. i)
      end
    end
  end
  net.ipv6_hint()
  return found and 0 or 1
end

os.exit(main())
