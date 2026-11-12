#!/usr/bin/env lua
-- Short guide to the commands on this stick. Run: serverstick-help.lua

local B, D, R = "\27[1m", "\27[2m", "\27[0m"

local sections = {
  { "ServerStick", {
    { "serverstick-status.lua", "overview: addresses, services, GPU, tailnet, join log (also shown at login)" },
    { "serverstick-help.lua", "this guide" },
    { "serverstick-gwscan.lua", "find the router: tests every machine on the cable for internet access" },
    { "  -i eno1 -a 192.168.1.50/24", "  scan one port, testing from a chosen address" },
    { "  --apply", "  configure the first gateway that works (until the link changes)" },
    { "serverstick-netfind.lua", "find a working gateway and a free address; --apply sets it, --undo removes it" },
    { "serverstick-autojoin.lua", "joins the tailnet; runs at boot (rerun: systemctl restart tailscale-autojoin)" },
  } },
  { "Network", {
    { "nmtui", "menu for wired / Wi-Fi / static address settings" },
    { "nmcli device", "ports and their state;  nmcli connection: saved profiles" },
    { "ip -br addr  /  ip route", "addresses and routes" },
    { "nmcli con add type ethernet ifname eno1 con-name static ipv4.method manual \\",
      "" },
    { "  ipv4.addresses 192.168.1.50/24 ipv4.gateway 192.168.1.1 ipv4.dns 1.1.1.1", "  fixed address by hand; then: nmcli con up static" },
    { "journalctl -u netfind-fallback -b", "what the automatic network fallback did this boot" },
  } },
  { "Tailscale", {
    { "tailscale status", "tailnet peers;  tailscale ip: this node's addresses" },
    { "tailscale netcheck", "can this network reach Tailscale (UDP, DERP relays)?" },
    { "journalctl -u tailscale-autojoin -b", "the join log, step 0/4 to 4/4" },
  } },
  { "Hardware and memory", {
    { "btop  /  nvtop", "CPU, RAM and process monitor  /  GPU monitor" },
    { "nvidia-smi", "GPU, driver and memory" },
    { "sensors", "temperatures and fans" },
    { "free -h;  df -h /run/archiso/cowspace /tmp", "RAM, and space left for files (all in RAM)" },
    { "lsblk", "disks (read only: the stick never mounts or changes them)" },
  } },
  { "Software and power", {
    { "pacman -Sy <package>", "install a package (in RAM: gone after reboot; add to EXTRA_PACKAGES to keep)" },
    { "journalctl -b -p warning", "every warning and error since boot" },
    { "reboot  /  poweroff", "restart / shut down" },
  } },
}

local width = 0
for _, s in ipairs(sections) do
  for _, c in ipairs(s[2]) do
    if c[2] ~= "" and #c[1] > width then width = #c[1] end
  end
end
width = math.min(width, 44)

for _, s in ipairs(sections) do
  io.write(B, "== ", s[1], R, "\n")
  for _, c in ipairs(s[2]) do
    if c[2] == "" or #c[1] > width then
      io.write("  ", c[1], "\n")
      if c[2] ~= "" then io.write("  ", string.rep(" ", width), "  ", D, c[2], R, "\n") end
    else
      io.write("  ", c[1], string.rep(" ", width - #c[1]), "  ", D, c[2], R, "\n")
    end
  end
end
io.write("\nLog in remotely with: ssh root@<hostname>  (Tailscale SSH, no password)\n")
