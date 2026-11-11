-- serverstick flash: write the ISO to a USB drive picked from a list, then compare it with the ISO.

local util = require("util")
local q, die, say = util.q, util.die, util.say

-- Parse one `lsblk -P` line (KEY="value" pairs) into a table.
local function parse_pairs(line)
  local t = {}
  for k, v in line:gmatch('([%w%-]+)="(.-)"') do t[k] = v end
  return t
end

-- Disks that hold the running system (/, /boot, /home, /usr, /var, swap), through LVM/LUKS/RAID.
local function system_disks()
  local sources = {}
  for _, m in ipairs({ "/", "/boot", "/boot/efi", "/efi", "/home", "/usr", "/var" }) do
    local src = util.capture("findmnt -nro SOURCE " .. q(m) .. " 2>/dev/null")
    if src ~= "" then sources[#sources + 1] = src end
  end
  for dev in util.lines_of("swapon --noheadings --show=NAME 2>/dev/null") do sources[#sources + 1] = dev end

  local disks = {}
  for _, src in ipairs(sources) do
    local dev = src:gsub("%[.*%]$", "")          -- btrfs subvolumes: /dev/x[/@home]
    if dev:sub(1, 5) == "/dev/" then
      -- -s walks up from the device to the disks it lives on.
      for line in util.lines_of("lsblk -nrspo PATH,TYPE " .. q(dev) .. " 2>/dev/null") do
        local path, kind = line:match("^(%S+)%s+(%S+)$")
        if kind == "disk" and not path:find("^/dev/zram") then disks[path] = true end
      end
    end
  end
  return disks
end

return function(root, args)
  local show_all = false
  if args[1] == "--all" then show_all = true; table.remove(args, 1) end
  local iso = args[1] or util.latest_iso(root)
  if not iso or not util.test("-f", iso) then die("no ISO found. Build one with ./serverstick build or pass a path") end
  local iso_bytes = util.size(iso)
  say("ISO: " .. iso .. " (" .. util.human(iso_bytes) .. ")")

  local system = system_disks()
  local cands = {}
  for line in util.lines_of("lsblk -dnpP -o PATH,SIZE,TYPE,TRAN,RM,HOTPLUG,MODEL") do
    local d = parse_pairs(line)
    local removable = d.TRAN == "usb" or d.RM == "1" or d.HOTPLUG == "1"
    local skip = d.TYPE ~= "disk" or d.PATH:find("^/dev/zram") or d.PATH:find("^/dev/loop")
      or system[d.PATH] or (not show_all and not removable)
    if not skip then
      local bytes = tonumber((util.capture("lsblk -bdno SIZE " .. q(d.PATH)))) or 0
      if bytes >= iso_bytes then
        local parts = {}
        for p in util.lines_of("lsblk -nro LABEL,FSTYPE,MOUNTPOINT " .. q(d.PATH)) do
          local part = p:match("^%s*(.-)%s*$")
          if part ~= "" then parts[#parts + 1] = part end
        end
        local model = d.MODEL:match("^%s*(.-)%s*$")
        cands[#cands + 1] = {
          dev = d.PATH,
          label = string.format("%-12s %8s  %-5s %-28s %s", d.PATH, d.SIZE, d.TRAN ~= "" and d.TRAN or "-",
            model ~= "" and model or "(no model)", #parts > 0 and "[" .. table.concat(parts, "; ") .. "]" or ""),
        }
      end
    end
  end

  if #cands == 0 then
    say("No suitable drive found (USB/removable, not your system disk, at least " .. util.human(iso_bytes) .. ").")
    if not show_all then say("Plug in a USB stick, or use --all to also list internal disks.") end
    return 1
  end

  local hidden = {}
  for d in pairs(system) do hidden[#hidden + 1] = d end
  table.sort(hidden)
  say("")
  say("Drives you can write to (hidden: the disk your system runs from"
    .. (#hidden > 0 and ", " .. table.concat(hidden, " ") or "") .. "):")
  for i, c in ipairs(cands) do say(string.format("  %d) %s", i, c.label)) end
  say("")
  io.write("Choose a drive [1-" .. #cands .. "], or q to quit: ")
  io.stdout:flush()
  local choice = cands[tonumber(io.read("*l") or "")]
  if not choice then say("Aborted."); return 1 end
  local dev, name = choice.dev, util.basename(choice.dev)

  say("")
  say("Selected: " .. choice.label)
  say("Current contents:")
  for line in util.lines_of("lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS " .. q(dev)) do say("  " .. line) end
  say("")
  say("EVERYTHING ON " .. dev .. " WILL BE ERASED.")
  io.write("Type the device name (" .. name .. ") to confirm: ")
  io.stdout:flush()
  if io.read("*l") ~= name then say("Aborted, nothing was written."); return 1 end

  -- Unmount anything mounted from the drive.
  for line in util.lines_of("lsblk -nrpo PATH,MOUNTPOINT " .. q(dev)) do
    local part, mnt = line:match("^(%S+)%s+(%S+)$")
    if mnt then
      say("Unmounting " .. part)
      local done = not util.is_root() and util.have("udisksctl")
        and util.run("udisksctl unmount -b " .. q(part) .. " >/dev/null 2>&1")
      if not done then util.must(util.priv("umount " .. q(part)), "cannot unmount " .. part) end
    end
  end

  say("Writing " .. iso .. " -> " .. dev)
  util.must(util.priv("dd if=" .. q(iso) .. " of=" .. q(dev) .. " bs=4M conv=fsync oflag=direct status=progress"), "dd failed")
  util.run("sync")

  say("Verifying written data")
  if not util.run(util.priv("cmp -n " .. string.format("%.0f", iso_bytes) .. " " .. q(iso) .. " " .. q(dev))) then
    die("verification failed: " .. dev .. " does not match the ISO. Try again or use another stick.")
  end
  say("OK: " .. dev .. " matches the ISO. You can unplug the drive.")
  return 0
end
