#!/usr/bin/env lua
-- ServerStick command line. Needs only a Lua interpreter (5.1-5.4 or LuaJIT) and the system
-- tools each command calls (archiso, qemu, util-linux, openssl, git).
--
--   ./serverstick.lua build                         build the ISO from .env, then verify it
--   ./serverstick.lua verify [iso]                  check an ISO without booting it
--   ./serverstick.lua flash [--all] [iso]           write the ISO to a USB drive picked from a list
--   ./serverstick.lua test-qemu [serial|bios|uefi] [iso]   boot the ISO headless in QEMU
--
-- Can run as your normal user (asks for sudo when needed) or as root / with sudo.

-- Find this script's directory so `tools/` and the project files resolve from anywhere.
local function script_dir()
  local self = arg and arg[0] or "serverstick.lua"
  local p = io.popen("readlink -f '" .. self:gsub("'", "'\\''") .. "'")
  local full = p:read("*l") or self
  p:close()
  return full:match("^(.*)/[^/]*$") or "."
end

local ROOT = script_dir()
package.path = ROOT .. "/tools/?.lua;" .. package.path

local util = require("util")

local COMMANDS = {
  build = "build",
  verify = "verify",
  flash = "flash",
  ["test-qemu"] = "qemu",
}

local function usage(out)
  out:write([[
usage: ./serverstick.lua <command> [args]

  build                              build the ISO from .env and packages.txt, then verify it
  verify [iso]                       check an ISO without booting it (default: newest in out/)
  flash [--all] [iso]                write the ISO to a USB drive you pick from a list
  test-qemu [serial|bios|uefi] [iso] boot the ISO headless in QEMU
]])
end

local name = arg[1]
if name == nil or name == "help" or name == "-h" or name == "--help" then
  usage(io.stdout)
  os.exit(name == nil and 2 or 0)
end
local module = COMMANDS[name]
if not module then
  io.stderr:write("unknown command '" .. name .. "'\n\n")
  usage(io.stderr)
  os.exit(2)
end

local args = {}
for i = 2, #arg do args[#args + 1] = arg[i] end

local ok, result = pcall(function() return require(module)(ROOT, args) end)
if not ok then
  if util.is_fatal(result) then
    io.stderr:write("ERROR: " .. result.msg .. "\n")
  else
    io.stderr:write("internal error: " .. tostring(result) .. "\n")
  end
  os.exit(1)
end
os.exit(tonumber(result) or 0)
