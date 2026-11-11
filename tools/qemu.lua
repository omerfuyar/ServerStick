-- serverstick test-qemu: headless QEMU boot test.
--
--   serial (default)  boots the ISO's kernel with the BIOS menu entry's params plus console=ttyS0,
--                     streams the journal to the serial log, checks tailscaled + tailscale-autojoin.
--   bios | uefi       boots through the real syslinux / systemd-boot menu, logs in on tty1
--                     (root + ROOT_PASSWORD from .env), and saves a screenshot of the status banner.
--
-- Env: QEMU_MEM (default 4G), QEMU_TIMEOUT seconds (default 300 serial, 150 bios/uefi).
-- With a real key in .env the VM really joins your tailnet (as an ephemeral node).
-- QEMU's monitor is its stdin, so no sockets are needed.

local util = require("util")
local config = require("config")
local q, die, say = util.q, util.die, util.say

-- QEMU `sendkey` names for a US keyboard layout (the live system's default).
local SHIFTED = {
  ["!"] = "1", ["@"] = "2", ["#"] = "3", ["$"] = "4", ["%"] = "5", ["^"] = "6", ["&"] = "7",
  ["*"] = "8", ["("] = "9", [")"] = "0", ["_"] = "minus", ["+"] = "equal", ["{"] = "bracket_left",
  ["}"] = "bracket_right", ["|"] = "backslash", [":"] = "semicolon", ['"'] = "apostrophe",
  ["<"] = "comma", [">"] = "dot", ["?"] = "slash", ["~"] = "grave_accent",
}
local PLAIN = {
  [" "] = "spc", ["-"] = "minus", ["="] = "equal", ["["] = "bracket_left", ["]"] = "bracket_right",
  ["\\"] = "backslash", [";"] = "semicolon", ["'"] = "apostrophe", [","] = "comma", ["."] = "dot",
  ["/"] = "slash", ["`"] = "grave_accent",
}

local function sendkey_name(ch)
  if ch:match("%l") or ch:match("%d") then return ch end
  if ch:match("%u") then return "shift-" .. ch:lower() end
  if PLAIN[ch] then return PLAIN[ch] end
  if SHIFTED[ch] then return "shift-" .. SHIFTED[ch] end
  die("test-qemu cannot type the character '" .. ch .. "' (use plain ASCII in ROOT_PASSWORD)")
end

-- Start QEMU with its monitor on our pipe; returns a handle with :send, :alive and :quit.
local function start_qemu(args, dir)
  local pidfile = dir .. "/qemu.pid"
  util.run("rm -f " .. q(pidfile))
  local pipe = io.popen(util.cmd(args) .. " -pidfile " .. q(pidfile) .. " > " .. q(dir .. "/monitor.log") .. " 2>&1", "w")
  local h = {}
  function h.send(line) pipe:write(line, "\n"); pipe:flush() end
  function h.alive()
    local pid = util.read(pidfile)
    return pid ~= nil and util.run("kill -0 " .. tonumber(pid) .. " 2>/dev/null")
  end
  function h.type(text)
    for i = 1, #text do
      h.send("sendkey " .. sendkey_name(text:sub(i, i)))
      util.sleep(0.1)
    end
    h.send("sendkey ret")
  end
  function h.quit()
    if h.alive() then h.send("quit") end
    pipe:close()
  end
  return h
end

local function find_first(paths)
  for _, p in ipairs(paths) do
    if util.test("-f", p) then return p end
  end
end

return function(root, args)
  local mode = args[1] or "serial"
  if mode ~= "serial" and mode ~= "bios" and mode ~= "uefi" then
    io.stderr:write("usage: serverstick test-qemu [serial|bios|uefi] [iso]\n")
    return 2
  end
  local iso = args[2] or util.latest_iso(root)
  if not iso or not util.test("-f", iso) then die("no ISO found in out/") end
  if not util.have("qemu-system-x86_64") then die("qemu-system-x86_64 not installed") end
  local env = config.load(root, false)

  local T = root .. "/build/qemu"
  util.mkdir(T)
  local log = T .. "/" .. mode .. "-serial.log"
  util.run("rm -f " .. q(log))

  local qemu = { "qemu-system-x86_64", "-machine", "q35", "-smp", "4", "-m", os.getenv("QEMU_MEM") or "4G",
    "-nic", "user,model=virtio-net-pci", "-display", "none", "-serial", "file:" .. log, "-monitor", "stdio",
    "-drive", "file=" .. iso .. ",media=cdrom,readonly=on,if=none,id=cd", "-device", "ide-cd,drive=cd", "-boot", "order=d" }
  if util.run("test -w /dev/kvm") then
    for _, a in ipairs({ "-enable-kvm", "-cpu", "host" }) do qemu[#qemu + 1] = a end
  end
  local function add(...) for _, a in ipairs({ ... }) do qemu[#qemu + 1] = a end end

  if mode == "serial" then
    local timeout = tonumber(os.getenv("QEMU_TIMEOUT") or "") or 300
    util.must("bsdtar -xf " .. q(iso) .. " -C " .. q(T)
      .. " arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img boot/syslinux/archiso_sys-linux.cfg",
      "cannot extract kernel from ISO")
    local cfg = util.read(T .. "/boot/syslinux/archiso_sys-linux.cfg") or ""
    local params = cfg:match("\nAPPEND (archisobasedir=[^\n]*)")
    if not params then die("no APPEND line in archiso_sys-linux.cfg") end
    params = params:gsub("%s+", " ") .. " console=ttyS0,115200 systemd.journald.forward_to_console=1"
    say("kernel params: " .. params)
    add("-kernel", T .. "/arch/boot/x86_64/vmlinuz-linux", "-initrd", T .. "/arch/boot/x86_64/initramfs-linux.img",
      "-append", params)

    local vm = start_qemu(qemu, T)
    say("booting (serial log: " .. log .. ", timeout " .. timeout .. "s)")
    local waited = 0
    while waited < timeout do
      util.sleep(5)
      waited = waited + 5
      if not vm.alive() then say("QEMU exited early"); break end
      local text = util.read(log) or ""
      if text:find("tailscale%-autojoin[^\n]*step 4/4") or text:find("tailscale%-autojoin[^\n]*giving up") then
        util.sleep(5)
        break
      end
    end
    vm.quit()

    local text = util.read(log) or ""
    local lines = {}
    for line in text:gmatch("[^\n]+") do
      if line:find("tailscale-autojoin", 1, true) then lines[#lines + 1] = line end
    end
    say("\n---- autojoin journal lines ----")
    for i = math.max(1, #lines - 39), #lines do say(lines[i]) end
    say("--------------------------------")

    local fails = 0
    local function chk(name, patterns)
      local ok = false
      for _, p in ipairs(patterns) do
        if text:find(p) then ok = true end
      end
      say((ok and "PASS  " or "FAIL  ") .. name)
      if not ok then fails = fails + 1 end
    end
    chk("copied to RAM (copytoram)", { "Copying rootfs image to RAM", "copytoram" })
    chk("tailscaled started", { "Started [^\n]*[Tt]ailscale node agent", "tailscaled[^\n]*Program starting", "tailscaled[^\n]*logtail started" })
    chk("tailscale-autojoin started", { "tailscale%-autojoin[^\n]*step 0/4" })
    chk("autojoin saw tailscaled socket", { "tailscale%-autojoin[^\n]*tailscaled is up" })
    chk("autojoin got network/DNS", { "tailscale%-autojoin[^\n]*controlplane%.tailscale%.com resolves" })
    if text:find("tailscale%-autojoin[^\n]*step 4/4") then
      say("INFO  join succeeded")
    else
      say("INFO  join did not succeed (fine in a VM)")
    end
    return fails
  end

  -- bios / uefi: real boot menu, log in on tty1, screenshot.
  local timeout = tonumber(os.getenv("QEMU_TIMEOUT") or "") or 150
  if mode == "uefi" then
    local code = find_first({ "/usr/share/edk2/x64/OVMF_CODE.4m.fd", "/usr/share/edk2-ovmf/x64/OVMF_CODE.4m.fd" })
    local vars = find_first({ "/usr/share/edk2/x64/OVMF_VARS.4m.fd", "/usr/share/edk2-ovmf/x64/OVMF_VARS.4m.fd" })
    if not code or not vars then die("OVMF firmware not found (pacman -S edk2-ovmf)") end
    util.must("cp " .. q(vars) .. " " .. q(T .. "/OVMF_VARS.fd"))
    add("-drive", "if=pflash,format=raw,readonly=on,file=" .. code, "-drive", "if=pflash,format=raw,file=" .. T .. "/OVMF_VARS.fd")
  end
  add("-vga", "std")

  local vm = start_qemu(qemu, T)
  local shot = T .. "/" .. mode .. "-tty1.png"
  local ok, err = pcall(function()
    say("booting " .. mode .. " through the real boot menu; logging in on tty1 after " .. timeout .. "s")
    util.sleep(timeout)
    if not vm.alive() then die("QEMU exited early") end
    vm.type("root")
    util.sleep(2)
    vm.type(env.ROOT_PASSWORD)
    util.sleep(8)
    util.run("rm -f " .. q(shot))
    vm.send("screendump " .. shot .. " -f png")
    util.sleep(2)
  end)
  vm.quit()
  if not ok then error(err, 0) end
  if not util.test("-f", shot) then die("screenshot was not written (see " .. T .. "/monitor.log)") end
  say("screenshot: " .. shot)
  return 0
end
