#!/usr/bin/env lua
-- Short status overview. Shown at console login; run again any time.

local self = io.popen("readlink -f '" .. (arg and arg[0] or ""):gsub("'", "'\\''") .. "'"):read("*l") or ""
package.path = (self:match("^(.*)/[^/]*$") or ".") .. "/../lib/serverstick/?.lua;" .. package.path

local sys = require("sys")
local net = require("net")
local capture, quiet = sys.capture, sys.quiet

local B, R = "\27[1m", "\27[0m"
local function out(s) io.stdout:write(s, "\n") end
local function head(s) out(B .. "== " .. s .. R) end
local function indent(text, prefix)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then out(prefix .. line) end
  end
end

local uptime = capture("uptime -p"):gsub("^up ", "")
head(capture("uname -n") .. " | " .. capture("uname -r") .. " | up " .. uptime)

head("IP addresses")
indent(capture("ip -br addr show | grep -v '^lo '"), "")
indent(capture("ip route show default"), "  route: ")
if not net.has_ipv4() then
  out("  " .. B .. "No IPv4 address." .. R
    .. " Find the gateway: serverstick-gwscan.lua  (apply: serverstick-netfind.lua --apply)  or configure: nmtui")
elseif not quiet("curl -sk -o /dev/null --connect-timeout 3 https://1.1.1.1/") then
  out("  " .. B .. "IPv4 but no internet" .. R .. " (1.1.1.1:443 unreachable). Wrong gateway? Test them: serverstick-gwscan.lua")
end

head("Services")
for _, u in ipairs({ "NetworkManager", "NetworkManager-wait-online", "netfind-fallback", "systemd-timesyncd",
    "tailscaled", "tailscale-autojoin" }) do
  out(string.format("  %-30s %s", u, capture("systemctl is-active " .. u .. " 2>&1")))
end
out(string.format("  %-30s %s (%s)", "clock synced",
  capture("timedatectl show -p NTPSynchronized --value 2>&1"), os.date("!%Y-%m-%d %H:%M:%S UTC")))
if quiet("lspci -d 10de: | grep -qiE 'vga|3d|display'") then
  indent(capture("nvidia-smi -L 2>&1"), "  ")
else
  out("  no NVIDIA GPU detected")
end

head("tailscale status")
indent(capture("tailscale status 2>&1 | head -n 15"), "")

head("journalctl -u tailscale-autojoin (last 20)")
indent(capture("journalctl -u tailscale-autojoin -n 20 --no-pager -o short --no-hostname 2>&1"), "")

out(B .. "Re-run: serverstick-status.lua | follow: journalctl -fu tailscale-autojoin" .. R)
