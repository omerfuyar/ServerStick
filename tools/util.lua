-- Shared helpers: logging, running commands, files, privileges.
-- Written for Lua 5.1+ (also LuaJIT): no goto, no integer division, no bit operators.

local M = {}

---------------------------------------------------------------- errors and logging

-- die() raises this so the CLI can run cleanups before exiting.
local Fatal = {}
Fatal.__index = Fatal

function M.die(msg)
  error(setmetatable({ msg = msg }, Fatal), 0)
end

function M.is_fatal(err)
  return getmetatable(err) == Fatal
end

function M.step(msg)
  io.write("\n==> ", msg, "\n")
  io.stdout:flush()
end

function M.say(msg)
  io.write(msg, "\n")
  io.stdout:flush()
end

---------------------------------------------------------------- shell commands

-- Quote one argument for /bin/sh.
function M.q(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Build a command line from a list of arguments, quoting each one.
function M.cmd(args)
  local parts = {}
  for i = 1, #args do
    parts[i] = M.q(args[i])
  end
  return table.concat(parts, " ")
end

-- os.execute returns a number in Lua 5.1 and (ok, how, code) in 5.2+; normalize to true/false.
local function execute(line)
  local a, _, c = os.execute(line)
  if type(a) == "number" then
    return a == 0
  end
  return a == true and (c == nil or c == 0)
end

-- Run a shell command line; returns true when it exits with status 0.
function M.run(line)
  io.stdout:flush()
  return execute(line)
end

-- Run a shell command line or die with `what`.
function M.must(line, what)
  if not M.run(line) then
    M.die((what or "command failed") .. ": " .. line)
  end
end

-- Run a command and return its stdout (trailing newline removed) and whether it succeeded.
function M.capture(line)
  local f = io.popen(line .. "; echo \"__rc=$?\"")
  local out = f:read("*a")
  f:close()
  local body, rc = out:match("^(.*)__rc=(%d+)%s*$")
  return (body or ""):gsub("\n$", ""), rc == "0"
end

-- Iterate over the lines a command prints.
function M.lines_of(line)
  local out = M.capture(line)
  return out:gmatch("[^\n]+")
end

function M.have(tool)
  return M.run("command -v " .. M.q(tool) .. " >/dev/null 2>&1")
end

function M.sleep(seconds)
  M.run("sleep " .. tonumber(seconds))
end

---------------------------------------------------------------- files

function M.read(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.write(path, content)
  local f, err = io.open(path, "wb")
  if not f then M.die("cannot write " .. path .. ": " .. tostring(err)) end
  f:write(content)
  f:close()
end

function M.append(path, content)
  local f, err = io.open(path, "ab")
  if not f then M.die("cannot write " .. path .. ": " .. tostring(err)) end
  f:write(content)
  f:close()
end

-- test(1) wrappers: M.test("-f", path), M.test("-L", path), ...
function M.test(flag, path)
  return M.run("test " .. flag .. " " .. M.q(path))
end

function M.mkdir(path, mode)
  local m = mode and ("-m " .. mode .. " ") or ""
  M.must("mkdir -p " .. m .. M.q(path), "cannot create directory")
end

-- Remove a tree, including read-only files extracted from an ISO.
function M.wipe(path, privileged)
  if not M.test("-e", path) and not M.test("-L", path) then return end
  local p = privileged and M.priv or function(s) return s end
  M.run(p("chmod -R u+w " .. M.q(path)) .. " 2>/dev/null")
  M.must(p("rm -rf " .. M.q(path)), "cannot remove")
end

function M.size(path)
  local out, ok = M.capture("stat -c %s " .. M.q(path))
  return ok and tonumber(out) or nil
end

-- Human-readable byte count, e.g. 2.0G.
function M.human(bytes)
  local out = M.capture("numfmt --to=iec " .. string.format("%.0f", bytes))
  return out
end

function M.basename(path)
  return (path:gsub("/+$", ""):match("([^/]+)$")) or path
end

-- Newest out/serverstick-*.iso, or nil.
function M.latest_iso(root)
  local out = M.capture("ls -t " .. M.q(root .. "/out") .. "/serverstick-*.iso 2>/dev/null")
  return out:match("^[^\n]+")
end

-- Split a string on whitespace.
function M.words(s)
  local t = {}
  for w in (s or ""):gmatch("%S+") do t[#t + 1] = w end
  return t
end

---------------------------------------------------------------- privileges

local uid = tonumber((M.capture("id -u")))

function M.is_root()
  return uid == 0
end

-- Prefix a command with sudo unless we already are root.
function M.priv(line)
  if M.is_root() then return line end
  return "sudo " .. line
end

-- The user who should own build outputs: the sudo caller when run with sudo, else ourselves.
function M.owner()
  local who = os.getenv("SUDO_USER")
  if M.is_root() and who and who ~= "" and who ~= "root" then
    local u = M.capture("id -u " .. M.q(who))
    local g = M.capture("id -g " .. M.q(who))
    return u .. ":" .. g
  end
  return M.capture("id -u") .. ":" .. M.capture("id -g")
end

-- Ask for sudo once and keep the timestamp fresh until this Lua process exits.
-- Returns a function that stops the keep-alive loop. No-op when already root.
function M.sudo_keepalive()
  if M.is_root() then return function() end end
  M.must("sudo -v", "sudo failed")
  local lua_pid = M.capture("echo $PPID")
  local pid = M.capture("(while kill -0 " .. lua_pid .. " 2>/dev/null && sudo -n true; do sleep 50; done)"
    .. " >/dev/null 2>&1 & echo $!")
  return function() M.run("kill " .. pid .. " 2>/dev/null") end
end

return M
