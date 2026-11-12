-- Small helpers for the ServerStick scripts: shell commands, files, logging.

local M = {}

io.stdout:setvbuf("line")

function M.log(msg)
  io.stdout:write(msg, "\n")
end

-- Quote one shell word.
function M.q(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

-- Run a command; true on exit status 0, plus the status.
function M.run(cmd)
  local a, _, c = os.execute(cmd)
  if type(a) == "number" then return a == 0, a end -- Lua 5.1
  return a == true, c or 0
end

-- Run a command quietly (stdout + stderr discarded).
function M.quiet(cmd)
  return M.run(cmd .. " >/dev/null 2>&1")
end

-- Output of a command (stderr kept separate), trailing newline removed, plus success flag.
function M.capture(cmd)
  local p = io.popen(cmd .. "; echo \"__rc=$?\"", "r")
  local out = p:read("*a")
  p:close()
  local body, rc = out:match("^(.-)\n?__rc=(%d+)\n?$")
  return body or out, tonumber(rc) == 0
end

-- Iterate over the lines of a command's output.
function M.lines(cmd)
  local out = M.capture(cmd)
  return (out .. "\n"):gmatch("([^\n]*)\n")
end

function M.read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.words(s)
  local t = {}
  for w in (s or ""):gmatch("[^%s,]+") do t[#t + 1] = w end
  return t
end

function M.sleep(seconds)
  os.execute("sleep " .. tonumber(seconds))
end

-- Seconds since boot (monotonic, fractional).
function M.now()
  local s = M.read("/proc/uptime")
  return tonumber(s and s:match("^(%S+)")) or os.time()
end

function M.is_root()
  local out = M.capture("id -u")
  return out == "0"
end

-- Parse argv: spec maps "-i"/"--iface" to { name, kind } with kind "flag", "value" or "list".
function M.parse_args(argv, spec, usage)
  local opts = {}
  for _, s in pairs(spec) do
    if s[2] == "list" then opts[s[1]] = {} end
  end
  local i = 1
  while i <= #argv do
    local a = argv[i]
    local key, inline = a:match("^(%-%-[^=]+)=(.*)$")
    key = key or a
    local s = spec[key]
    if a == "-h" or a == "--help" then
      io.stdout:write(usage)
      os.exit(0)
    elseif not s then
      io.stderr:write("unknown option '" .. a .. "'\n\n" .. usage)
      os.exit(2)
    elseif s[2] == "flag" then
      opts[s[1]] = true
    else
      local v = inline
      if not v then
        i = i + 1
        v = argv[i]
      end
      if not v then
        io.stderr:write("option " .. key .. " needs a value\n")
        os.exit(2)
      end
      if s[2] == "list" then
        local l = opts[s[1]]
        l[#l + 1] = v
      else
        opts[s[1]] = v
      end
    end
    i = i + 1
  end
  return opts
end

return M
