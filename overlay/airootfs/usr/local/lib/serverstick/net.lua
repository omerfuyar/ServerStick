-- Network discovery for serverstick-netfind.lua and serverstick-gwscan.lua.
--
-- Finds the gateway on a network where DHCP gives nothing: listen to ARP/IPv4 traffic on the
-- wire with tcpdump (no IPv4 needed), collect every address that could be the router, then test
-- each one by routing a public address through it and checking that the internet answers.
-- Only a gateway that passed that test is ever applied.

local sys = require("sys")
local q, log, run, quiet, capture = sys.q, sys.log, sys.run, sys.quiet, sys.capture

local M = {}

M.PROFILE_PREFIX = "netfind-"
M.STATIC_PROFILE = "serverstick-static"
M.DHCP_PROFILE = "serverstick-dhcp"
M.NETWORK_CONF = "/etc/serverstick/network.conf"
M.FALLBACK_DNS = { "1.1.1.1", "9.9.9.9" }
-- Public addresses used to test a gateway (TCP 443, then ping); one per candidate in a batch,
-- so a whole batch is tested at the same time.
M.TEST_TARGETS = { "1.1.1.1", "8.8.8.8", "9.9.9.9", "1.0.0.1", "8.8.4.4", "149.112.112.112",
  "208.67.222.222", "208.67.220.220" }
-- ARP-probed when the wire is too quiet to learn anything by listening.
M.COMMON_GATEWAYS = {
  "192.168.1.1", "192.168.0.1", "192.168.1.254", "192.168.0.254", "192.168.2.1", "192.168.10.1",
  "192.168.100.1", "192.168.178.1", "192.168.8.1", "192.168.31.1", "192.168.50.1", "192.168.88.1",
  "192.168.43.1", "10.0.0.1", "10.0.0.138", "10.0.1.1", "10.1.1.1", "10.10.10.1", "172.16.0.1",
  "172.20.10.1",
}

------------------------------------------------------------------ IPv4 numbers

-- "a.b.c.d" -> number, or nil.
function M.ip2n(s)
  local a, b, c, d = tostring(s or ""):match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
  if not a then return nil end
  a, b, c, d = tonumber(a), tonumber(b), tonumber(c), tonumber(d)
  if a > 255 or b > 255 or c > 255 or d > 255 then return nil end
  return ((a * 256 + b) * 256 + c) * 256 + d
end

function M.n2ip(n)
  local d = n % 256
  n = (n - d) / 256
  local c = n % 256
  n = (n - c) / 256
  local b = n % 256
  local a = (n - b) / 256
  return string.format("%d.%d.%d.%d", a, b, c, d)
end

-- First address of the network of size 2^(32-prefix) that holds n.
function M.base(n, prefix)
  local size = 2 ^ (32 - prefix)
  return n - n % size
end

-- Unicast, not 0.x / loopback / link-local / multicast / reserved.
function M.usable(n)
  if not n then return false end
  local a = math.floor(n / 16777216)
  local ab = math.floor(n / 65536)
  return a ~= 0 and a ~= 127 and a < 224 and ab ~= 169 * 256 + 254
end

function M.is_private(n)
  local a = math.floor(n / 16777216)
  local ab = math.floor(n / 65536)
  return a == 10 or (ab >= 172 * 256 + 16 and ab <= 172 * 256 + 31) or ab == 192 * 256 + 168
end

-- "a.b.c.d/nn" (or "a.b.c.d", /24) -> { ip = n, prefix = nn }, or nil.
function M.parse_cidr(s)
  local ip, p = tostring(s or ""):match("^([%d.]+)/(%d+)$")
  if not ip then ip, p = s, "24" end
  local n, pfx = M.ip2n(ip), tonumber(p)
  if not n or not pfx or pfx < 8 or pfx > 32 then return nil end
  return { ip = n, prefix = pfx }
end

function M.cidr(a)
  return M.n2ip(a.ip) .. "/" .. a.prefix
end

------------------------------------------------------------------ config

-- STATIC_IP (a.b.c.d/nn), STATIC_GATEWAY, STATIC_DNS (space separated), FALLBACK_WAIT (seconds)
-- from the build's .env.
function M.read_conf(path)
  local conf = { STATIC_IP = "", STATIC_GATEWAY = "", STATIC_DNS = "", FALLBACK_WAIT = "" }
  for line in ((sys.read(path or M.NETWORK_CONF) or "") .. "\n"):gmatch("([^\n]*)\n") do
    local k, v = line:match("^%s*([%u_]+)=(.*)$")
    if k and conf[k] then conf[k] = sys.trim(v):gsub('^"(.*)"$', "%1") end
  end
  conf.wait = tonumber(conf.FALLBACK_WAIT) or 45
  conf.static = conf.STATIC_IP ~= "" and M.parse_cidr(conf.STATIC_IP) or nil
  if conf.STATIC_IP ~= "" and not conf.static then
    log("ignoring invalid STATIC_IP '" .. conf.STATIC_IP .. "' in " .. M.NETWORK_CONF)
  end
  return conf
end

------------------------------------------------------------------ interfaces

-- { ifname = { "a.b.c.d/nn", ... } } for global IPv4 addresses, Tailscale excluded.
function M.global_ipv4()
  local have = {}
  for line in sys.lines("ip -4 -o addr show scope global 2>/dev/null") do
    local name, addr = line:match("^%d+:%s+([^%s@:]+)[^%s]*%s+inet%s+([%d.]+/%d+)")
    if name and not name:match("^tailscale") then
      have[name] = have[name] or {}
      table.insert(have[name], addr)
    end
  end
  return have
end

function M.has_ipv4()
  return next(M.global_ipv4()) ~= nil
end

local function sysfs(name, attr)
  local s = sys.read("/sys/class/net/" .. name .. "/" .. attr)
  return s and sys.trim(s) or ""
end

local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() end
  return f ~= nil
end

function M.is_wireless(name) return exists("/sys/class/net/" .. name .. "/wireless") end
function M.has_carrier(name) return sysfs(name, "carrier") == "1" end

function M.physical_ifaces()
  local list = {}
  for name in sys.lines("ls /sys/class/net") do
    if name ~= "" and exists("/sys/class/net/" .. name .. "/device") then list[#list + 1] = name end
  end
  table.sort(list)
  return list
end

-- Ports to scan: the requested ones, or every physical port with a link (and no IPv4 unless force).
function M.pick_ifaces(requested, force, wired_only)
  local have = M.global_ipv4()
  local picked = {}
  local names = (requested and #requested > 0) and requested or M.physical_ifaces()
  local explicit = requested and #requested > 0
  for _, n in ipairs(names) do
    if not exists("/sys/class/net/" .. n) then
      log("[" .. n .. "] no such interface")
    elseif not (wired_only and M.is_wireless(n)) then
      if explicit and not M.has_carrier(n) then
        quiet("ip link set " .. q(n) .. " up")
        for _ = 1, 10 do
          if M.has_carrier(n) then break end
          sys.sleep(0.5)
        end
      end
      if not M.has_carrier(n) then
        log("[" .. n .. "] no link (cable unplugged / Wi-Fi not associated), skipped")
      elseif have[n] and not force and not explicit then
        log("[" .. n .. "] already has " .. table.concat(have[n], ", ") .. ", skipped (use -i " .. n .. " to scan anyway)")
      else
        picked[#picked + 1] = n
      end
    end
  end
  return picked
end

------------------------------------------------------------------ listening (tcpdump)

-- A wire map for ifname:
--   asked[ip] = { [asker] = true, n = count }   who ARPs for whom
--   hosts[ip] = mac                              every host seen
--   replies[ip] = mac                            ARP replies (incl. to our probes)
function M.new_wire(ifname)
  local own = {}
  for _, a in ipairs(M.global_ipv4()[ifname] or {}) do own[M.ip2n(a:match("^[^/]+"))] = true end
  return { ifname = ifname, asked = {}, hosts = {}, replies = {}, own = own, frames = 0, listened = 0 }
end

local function tcpdump_cmd(ifname, seconds)
  return "timeout " .. math.max(1, math.floor(seconds)) .. " tcpdump -l -t -n -e -p -Q in -i " .. q(ifname)
    .. " 'arp or ip' 2>/dev/null"
end

-- Listen on ifname for `seconds` (adding to wire map w if given).
function M.listen(ifname, seconds, w)
  w = w or M.new_wire(ifname)
  local p = io.popen(tcpdump_cmd(ifname, seconds), "r")
  for line in p:lines() do M.parse_frame(w, line) end
  p:close()
  w.listened = w.listened + seconds
  return w
end

-- Listen in the background (e.g. while waiting for DHCP). Returns a handle for capture_finish.
function M.capture_start(ifname, max_seconds)
  quiet("mkdir -p /run/serverstick")
  local path = "/run/serverstick/wire-" .. ifname .. ".txt"
  local pid = capture(tcpdump_cmd(ifname, max_seconds) .. " > " .. q(path) .. " & echo $!")
  return { ifname = ifname, path = path, pid = tonumber(pid), started = sys.now() }
end

-- Stop a background capture and turn it into a wire map.
function M.capture_finish(cap)
  if cap.pid then quiet("kill " .. cap.pid) end
  sys.sleep(0.2)
  local w = M.new_wire(cap.ifname)
  for line in ((sys.read(cap.path) or "") .. "\n"):gmatch("([^\n]*)\n") do M.parse_frame(w, line) end
  os.remove(cap.path)
  w.listened = sys.now() - cap.started
  return w
end

-- One line of `tcpdump -t -n -e` output into the wire map.
function M.parse_frame(w, line)
  local smac, kind, rest = line:match("^(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x) > %S+, ethertype (%S+) %(0x%x+%), length %d+: (.*)$")
  if not smac then return end
  w.frames = w.frames + 1
  if kind == "ARP" then
    local target, sender = rest:match("^Request who%-has ([%d.]+).- tell ([%d.]+)")
    if target then
      local t, s = M.ip2n(target), M.ip2n(sender)
      if not M.usable(s) or w.own[s] then return end
      w.hosts[s] = smac
      if M.usable(t) and t ~= s then -- t == s is a gratuitous announcement
        local a = w.asked[t] or { n = 0 }
        if not a[s] then
          a[s] = true
          a.n = a.n + 1
        end
        w.asked[t] = a
      end
      return
    end
    local ip, mac = rest:match("^Reply ([%d.]+) is%-at (%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)")
    local n = M.ip2n(ip)
    if n and M.usable(n) and not w.own[n] then
      w.hosts[n] = mac
      w.replies[n] = mac
    end
  elseif kind == "IPv4" then
    local n = M.ip2n(rest:match("^(%d+%.%d+%.%d+%.%d+)"))
    if n and M.usable(n) and M.is_private(n) and not w.own[n] and not w.hosts[n] then
      w.hosts[n] = smac
    end
  end
end

-- RFC 5227 ARP probes (sender 0.0.0.0, via arping -D): need no address and claim none.
-- Answers land in w.replies / w.hosts. ips are numbers.
function M.probe(w, ips)
  if #ips == 0 then return end
  local parts = {}
  for i, n in ipairs(ips) do
    parts[#parts + 1] = string.format(
      "( o=$(arping -D -c 2 -w 3 -I %s %s 2>/dev/null); r=$?; echo \"%d $r $(printf '%%s' \"$o\" | grep -o '\\[[0-9A-Fa-f:]*\\]' | head -n1)\" ) &",
      q(w.ifname), M.n2ip(n), i)
  end
  local out = capture("{ " .. table.concat(parts, " ") .. " wait; }")
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    local i, rc, mac = line:match("^(%d+) (%d+) ?%[?([%x:]*)%]?")
    local n = i and ips[tonumber(i)]
    if n and rc == "1" then
      mac = (mac ~= "" and mac:lower()) or "?"
      w.replies[n] = mac
      w.hosts[n] = w.hosts[n] or mac
    end
  end
end

function M.in_use(w, n)
  M.probe(w, { n })
  return w.replies[n] ~= nil
end

------------------------------------------------------------------ candidates

local function asked_count(w, n)
  return w.asked[n] and w.asked[n].n or 0
end

local function sorted_keys(t)
  local list = {}
  for k in pairs(t) do list[#list + 1] = k end
  table.sort(list)
  return list
end

-- Every address that might be the router, most likely first: `first` (STATIC_GATEWAY, -g),
-- addresses other hosts ARP for (most askers first), .1/.254 of every /24 seen (ours first),
-- then the other hosts.
function M.candidates(w, first, limit, near)
  local order = {}
  for _, a in ipairs(first or {}) do order[#order + 1] = M.ip2n(a) end
  local ranked = sorted_keys(w.asked)
  table.sort(ranked, function(x, y)
    local cx, cy = asked_count(w, x), asked_count(w, y)
    if cx ~= cy then return cx > cy end
    local ex, ey = (x % 256 == 1 or x % 256 == 254), (y % 256 == 1 or y % 256 == 254)
    if ex ~= ey then return ex end
    return x < y
  end)
  for _, n in ipairs(ranked) do order[#order + 1] = n end
  local nets, seen_net = {}, {}
  local function add_net(n)
    local b = M.base(n, 24)
    if not seen_net[b] then
      seen_net[b] = true
      nets[#nets + 1] = b
    end
  end
  for _, n in ipairs(near or {}) do add_net(n) end
  for n in pairs(w.own) do add_net(n) end
  for _, n in ipairs(sorted_keys(w.hosts)) do add_net(n) end
  for _, n in ipairs(ranked) do add_net(n) end
  for _, b in ipairs(nets) do
    order[#order + 1] = b + 1
    order[#order + 1] = b + 254
  end
  for _, n in ipairs(sorted_keys(w.hosts)) do order[#order + 1] = n end

  local out, seen = {}, {}
  local skip = {}
  for _, n in ipairs(near or {}) do skip[n] = true end
  for _, n in ipairs(order) do
    if n and not seen[n] and not w.own[n] and not skip[n] and M.usable(n) then
      seen[n] = true
      out[#out + 1] = n
      if #out >= (limit or 64) then break end
    end
  end
  return out
end

-- Nothing heard: ARP-probe common router addresses and return the ones that answered.
function M.quiet_wire_candidates(w)
  local guesses = {}
  for _, g in ipairs(M.COMMON_GATEWAYS) do guesses[#guesses + 1] = M.ip2n(g) end
  M.probe(w, guesses)
  local out = {}
  for _, g in ipairs(guesses) do
    if w.replies[g] then out[#out + 1] = g end
  end
  return out
end

-- Smallest network (/24 down to /16) around the gateway that holds every host that ARPed for it.
function M.infer_prefix(w, gw)
  if M.base(gw, 28) == M.ip2n("172.20.10.0") then return 28 end -- iPhone hotspot
  for prefix = 24, 16, -1 do
    local b = M.base(gw, prefix)
    local ok = true
    for peer in pairs(w.asked[gw] or {}) do
      if peer ~= "n" and M.base(peer, prefix) ~= b then ok = false end
    end
    if ok then return prefix end
  end
  return 24
end

-- An address nobody answers for, near gw: .250 down to .200 first, then the rest of the /24.
function M.free_address(w, gw)
  local b = M.base(gw, 24)
  local pool = {}
  for i = 250, 200, -1 do pool[#pool + 1] = b + i end
  for i = 199, 2, -1 do pool[#pool + 1] = b + i end
  local filtered = {}
  for _, n in ipairs(pool) do
    if n ~= gw and not w.hosts[n] and not w.own[n] then filtered[#filtered + 1] = n end
  end
  for i = 1, math.min(#filtered, 64), 8 do
    local batch = {}
    for j = i, math.min(i + 7, #filtered) do batch[#batch + 1] = filtered[j] end
    M.probe(w, batch)
    for _, n in ipairs(batch) do
      if not w.hosts[n] then return n end
    end
  end
  return nil
end

------------------------------------------------------------------ internet tests

-- Shell snippet printing "tcp/443", "ping" or "none" for one target (optionally from address src).
local function reach_snippet(target, src, timeout)
  local t = tostring(timeout or 2)
  local iface = src and (" --interface " .. src) or ""
  local pingsrc = src and (" -I " .. src) or ""
  -- curl exit 7 (refused/unreachable), 28 (timeout), 45 (bind failed): no TCP connection.
  -- Anything else (TLS errors included) means the TCP handshake worked.
  return "curl -sk -o /dev/null --connect-timeout " .. t .. " --max-time " .. (t + 2) .. iface
    .. " https://" .. target .. "/ >/dev/null 2>&1; c=$?; "
    .. "if [ $c -ne 7 ] && [ $c -ne 28 ] && [ $c -ne 45 ]; then echo tcp/443; "
    .. "elif ping -n -q -c 1 -W " .. t .. pingsrc .. " " .. target .. " >/dev/null 2>&1; then echo ping; "
    .. "else echo none; fi"
end

-- Run snippets in parallel; returns their one-line outputs in order.
local function parallel(snippets)
  local parts = {}
  for i, s in ipairs(snippets) do
    parts[#parts + 1] = "( r=$(" .. s .. "); echo \"" .. i .. " $r\" ) &"
  end
  local res = {}
  local out = capture("{ " .. table.concat(parts, " ") .. " wait; }")
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    local i, r = line:match("^(%d+) (%S+)")
    if i then res[tonumber(i)] = r end
  end
  return res
end

-- Can this box reach the internet over its normal routes? "target via method" or nil.
function M.internet_ok(timeout)
  local snippets = {}
  for i = 1, 3 do snippets[i] = reach_snippet(M.TEST_TARGETS[i], nil, timeout or 3) end
  local res = parallel(snippets)
  for i = 1, 3 do
    if res[i] and res[i] ~= "none" then return M.TEST_TARGETS[i] .. " via " .. res[i] end
  end
  return nil
end

-- State and MAC of the kernel's ARP entry for n, e.g. "REACHABLE", "aa:bb:...".
function M.neighbor(ifname, n)
  local line = capture("ip neigh show " .. M.n2ip(n) .. " dev " .. q(ifname) .. " 2>/dev/null")
  if line == "" then return "NONE", nil end
  return line:match("(%u+)%s*$") or "?", line:match("lladdr (%S+)")
end

function M.on_wire(state)
  return state == "REACHABLE" or state == "STALE" or state == "DELAY" or state == "PROBE" or state == "PERMANENT"
end

-- Route a public address through each candidate and check that the internet answers.
-- src = { ip, prefix }; added to the port as a /32 for the test if missing. Only /32 routes to
-- the test targets are touched; the default route is left alone. Returns results in candidate order.
function M.test_gateways(ifname, src, cands, stop_first)
  local ip = M.n2ip(src.ip)
  local added = true
  for _, a in ipairs(M.global_ipv4()[ifname] or {}) do
    if a:match("^[^/]+") == ip then added = false end
  end
  if added and not quiet("ip addr add " .. ip .. "/32 dev " .. q(ifname)) then
    log("[" .. ifname .. "] cannot add test address " .. ip)
    return {}
  end
  local results = {}
  local ok, err = pcall(function()
    local n = #M.TEST_TARGETS
    for i = 1, #cands, n do
      local batch = {}
      for j = i, math.min(i + n - 1, #cands) do
        batch[#batch + 1] = { gw = cands[j], target = M.TEST_TARGETS[j - i + 1] }
      end
      local snippets = {}
      for k, b in ipairs(batch) do
        quiet("ip route replace " .. b.target .. "/32 via " .. M.n2ip(b.gw) .. " dev " .. q(ifname)
          .. " onlink src " .. ip)
        snippets[k] = reach_snippet(b.target, ip, 2)
      end
      local res = parallel(snippets)
      for k, b in ipairs(batch) do
        quiet("ip route del " .. b.target .. "/32 dev " .. q(ifname))
        local state, mac = M.neighbor(ifname, b.gw)
        local how = res[k] ~= "none" and res[k] or nil
        results[#results + 1] = { gw = b.gw, ok = how, target = b.target, state = state, mac = mac }
      end
      if stop_first then
        for _, r in ipairs(results) do
          if r.ok then return end
        end
      end
    end
  end)
  if added then quiet("ip addr del " .. ip .. "/32 dev " .. q(ifname)) end
  if not ok then error(err, 0) end
  return results
end

------------------------------------------------------------------ the scan

-- Listen, collect candidates, pick a source address, test the candidates.
-- opts: addr ({ip,prefix}), first (list of "a.b.c.d"), stop_first, limit, quiet,
--       wire (map from capture_finish; topped up with listening until listen_s is reached).
-- Returns { ifname, src, src_how, prefix, results, best, wire } or nil.
function M.scan(ifname, listen_s, conf, opts)
  opts = opts or {}
  local tag = "[" .. ifname .. "] "
  local w = opts.wire
  if w and w.listened >= listen_s then
    log(tag .. string.format("using %ds of traffic heard while waiting for DHCP (%d frames)", math.floor(w.listened), w.frames))
  else
    local more = listen_s - (w and w.listened or 0)
    log(tag .. "listening to ARP/broadcast traffic for " .. math.ceil(more) .. "s (no IPv4 needed) ...")
    w = M.listen(ifname, math.ceil(more), w)
  end
  local static = conf.static
  local first = {}
  for _, g in ipairs(opts.first or {}) do first[#first + 1] = g end
  if conf.STATIC_GATEWAY ~= "" then first[#first + 1] = conf.STATIC_GATEWAY end
  local near = {}
  if opts.addr then near[#near + 1] = opts.addr.ip end
  if static then near[#near + 1] = static.ip end
  local cands = M.candidates(w, first, opts.limit or 64, near)
  local nhosts = #sorted_keys(w.hosts)
  if nhosts == 0 and #cands == 0 then
    log(tag .. "heard " .. w.frames .. " frames and no hosts; probing " .. #M.COMMON_GATEWAYS .. " common router addresses")
    cands = M.quiet_wire_candidates(w)
  end
  log(tag .. nhosts .. " host(s) seen, " .. #cands .. " gateway candidate(s)")
  if #cands == 0 then
    log(tag .. "nothing to test: empty network or isolated port?")
    return nil
  end

  -- Source address for the test (and later the static config).
  local own = M.global_ipv4()[ifname]
  local src, how
  if opts.addr then
    src, how = opts.addr, "given with -a"
  elseif static then
    src, how = static, "STATIC_IP from .env"
  elseif own then
    src, how = M.parse_cidr(own[1]), "already on the port"
  else
    local free = M.free_address(w, cands[1])
    if not free then
      log(tag .. "no free address found near " .. M.n2ip(cands[1]) .. "; pass one with -a a.b.c.d/nn")
      return nil
    end
    src, how = { ip = free, prefix = M.infer_prefix(w, cands[1]) }, "free: nobody answered an ARP probe for it"
  end
  if not w.own[src.ip] and M.in_use(w, src.ip) then
    log(tag .. "WARNING: " .. M.n2ip(src.ip) .. " is already used by " .. (w.replies[src.ip] or "?")
      .. ": another machine has this address")
  end
  log(tag .. "testing " .. #cands .. " candidate(s) from " .. M.cidr(src) .. "  (" .. how .. ")")
  local results = M.test_gateways(ifname, src, cands, opts.stop_first)
  local best
  for _, r in ipairs(results) do
    if r.ok and not best then best = r end
    if not opts.quiet then
      local mark = r.ok and ("INTERNET OK (" .. r.ok .. " to " .. r.target .. ")")
        or (M.on_wire(r.state) and "on the wire, no internet" or "no ARP answer")
      local nask = asked_count(w, r.gw)
      log(string.format("%s  %-16s %-18s %s%s", tag, M.n2ip(r.gw), r.mac or "?", mark,
        nask > 0 and (", ARPed for by " .. nask) or ""))
    end
  end
  if best then
    log(tag .. "gateway " .. M.n2ip(best.gw) .. " reaches the internet")
  else
    log(tag .. "none of the " .. #results .. " candidate(s) reached the internet")
  end
  return { ifname = ifname, src = src, src_how = how, explicit_prefix = (opts.addr or static) and src.prefix,
    results = results, best = best, wire = w }
end

-- address/prefix, gateway and DNS list to apply for a scan result with a working gateway.
function M.config_for(res, conf)
  local gw = res.best.gw
  local prefix = res.explicit_prefix or M.infer_prefix(res.wire, gw)
  local dns = sys.words(conf.STATIC_DNS)
  if #dns == 0 then
    dns = { M.n2ip(gw) }
    for _, d in ipairs(M.FALLBACK_DNS) do dns[#dns + 1] = d end
  end
  return M.n2ip(res.src.ip) .. "/" .. prefix, M.n2ip(gw), dns
end

------------------------------------------------------------------ NetworkManager

function M.nm_profiles()
  local list = {}
  for name in sys.lines("nmcli -g NAME connection show 2>/dev/null") do
    if name ~= "" then list[#list + 1] = name end
  end
  return list
end

function M.has_profile(name)
  for _, n in ipairs(M.nm_profiles()) do
    if n == name then return true end
  end
  return false
end

-- Create and activate a static profile netfind-<if>; true if the internet is reachable afterwards.
-- It does not autoconnect: after a cable unplug or link change NetworkManager tries DHCP again,
-- and netfind-fallback.service runs the scan again if that fails.
function M.apply(ifname, addr, gw, dns)
  local name = M.PROFILE_PREFIX .. ifname
  local tag = "[" .. ifname .. "] "
  quiet("nmcli connection delete " .. q(name))
  local out, ok = capture("nmcli connection add type ethernet ifname " .. q(ifname) .. " con-name " .. q(name)
    .. " connection.autoconnect no ipv4.method manual"
    .. " ipv4.addresses " .. q(addr) .. " ipv4.gateway " .. q(gw) .. " ipv4.dns " .. q(table.concat(dns, ","))
    .. " ipv6.method auto 2>&1")
  if not ok then
    log(tag .. "nmcli connection add failed: " .. out)
    return false
  end
  out, ok = capture("nmcli --wait 30 connection up " .. q(name) .. " 2>&1")
  if not ok then
    log(tag .. "nmcli connection up failed: " .. out)
    return false
  end
  local inet = M.internet_ok()
  log(tag .. "applied profile '" .. name .. "': " .. addr .. " via " .. gw .. ", dns " .. table.concat(dns, " ")
    .. " (internet " .. (inet and ("OK: " .. inet) or "NOT reachable") .. "). Undo: serverstick-netfind.lua --undo")
  return inet ~= nil
end

function M.undo()
  local any = false
  for _, n in ipairs(M.nm_profiles()) do
    if n:sub(1, #M.PROFILE_PREFIX) == M.PROFILE_PREFIX then
      quiet("nmcli connection delete " .. q(n))
      log("deleted " .. n)
      any = true
    end
  end
  if not any then log("no netfind profiles found") end
end

function M.ipv6_hint()
  local routes = capture("ip -6 route show default 2>/dev/null")
  if routes ~= "" then
    log("IPv6 default route present (Tailscale can also connect over IPv6):")
    for line in (routes .. "\n"):gmatch("([^\n]+)\n") do log("  " .. line) end
  end
end

return M
