#!/usr/bin/env lua
-- Find the default gateway by testing which machine on the wire really reaches the internet.

local USAGE = [[
Find the default gateway: list every address on the wire that could be the router and test
which ones actually reach the internet. Works without an IPv4 address (no DHCP needed).

How: listen to ARP/IPv4 traffic (tcpdump), collect candidates (STATIC_GATEWAY, addresses other
hosts ARP for, .1/.254 of every subnet seen, all other hosts), then for each one temporarily
route a public address (1.1.1.1, 8.8.8.8, ...) through it and try TCP 443 / ping. Only those /32
test routes and, if needed, a temporary /32 test address are added; both are removed afterwards.
The default route and NetworkManager profiles are not touched unless you pass --apply.

  serverstick-gwscan.lua                       scan every wired port with a link
  serverstick-gwscan.lua -i eno1 -t 30         one port, listen for 30 s (more hosts on a quiet LAN)
  serverstick-gwscan.lua -a 192.168.1.50/24    test from this address (default: STATIC_IP, the port's
                                               current IPv4, or a free one found by ARP probing)
  serverstick-gwscan.lua -g 192.168.1.254      test this candidate first (repeatable)
  serverstick-gwscan.lua --apply               configure the first working gateway (NetworkManager)

Options: -i/--iface IF  -t/--time SECONDS (15)  -a/--addr A.B.C.D/NN  -g/--gateway A.B.C.D
         -n/--max N (64)  --apply
]]

local self = io.popen("readlink -f '" .. (arg and arg[0] or ""):gsub("'", "'\\''") .. "'"):read("*l") or ""
package.path = (self:match("^(.*)/[^/]*$") or ".") .. "/../lib/serverstick/?.lua;" .. package.path

local sys = require("sys")
local net = require("net")
local log = sys.log

local opts = sys.parse_args(arg, {
  ["-i"] = { "iface", "list" }, ["--iface"] = { "iface", "list" },
  ["-t"] = { "time", "value" }, ["--time"] = { "time", "value" },
  ["-a"] = { "addr", "value" }, ["--addr"] = { "addr", "value" },
  ["-g"] = { "gateway", "list" }, ["--gateway"] = { "gateway", "list" },
  ["-n"] = { "max", "value" }, ["--max"] = { "max", "value" },
  ["--apply"] = { "apply", "flag" },
}, USAGE)

local function main()
  if not sys.is_root() then
    io.stderr:write("serverstick-gwscan.lua needs root (packet capture, test routes)\n")
    return 1
  end
  local addr
  if opts.addr then
    addr = net.parse_cidr(opts.addr)
    if not addr then
      io.stderr:write("invalid address '" .. opts.addr .. "' (want a.b.c.d/nn)\n")
      return 2
    end
  end
  for _, g in ipairs(opts.gateway) do
    if not net.ip2n(g) then
      io.stderr:write("invalid gateway '" .. g .. "'\n")
      return 2
    end
  end

  local conf = net.read_conf()
  local ifaces = net.pick_ifaces(opts.iface, true, #opts.iface == 0)
  if #ifaces == 0 then
    log("no wired port with a link")
    return 1
  end
  local working = {}
  for _, i in ipairs(ifaces) do
    local res = net.scan(i, tonumber(opts.time or 15), conf,
      { addr = addr, first = opts.gateway, limit = tonumber(opts.max or 64) })
    if res and res.best then
      working[#working + 1] = res
      local a, gw, dns = net.config_for(res, conf)
      log("[" .. i .. "] config:  " .. a .. " via " .. gw .. ", dns " .. table.concat(dns, " "))
      log("[" .. i .. "] apply:   serverstick-gwscan.lua --apply -i " .. i .. (opts.addr and (" -a " .. a) or "")
        .. "   (or until reboot: ip addr add " .. a .. " dev " .. i .. " && ip route add default via " .. gw .. ")")
    end
  end
  if opts.apply then
    for _, res in ipairs(working) do
      local a, gw, dns = net.config_for(res, conf)
      if not net.is_wireless(res.ifname) and net.apply(res.ifname, a, gw, dns) then return 0 end
    end
    log("nothing applied")
    return 1
  end
  return #working > 0 and 0 or 1
end

os.exit(main())
