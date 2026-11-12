#!/usr/bin/env lua
-- Join the tailnet with the baked-in auth key. Run by tailscale-autojoin.service.
-- Every line goes to the journal: journalctl -u tailscale-autojoin
--
-- Tunables (env, optional): SOCKET_TIMEOUT, NET_TIMEOUT, CLOCK_TIMEOUT, MAX_ATTEMPTS

local self = io.popen("readlink -f '" .. (arg and arg[0] or ""):gsub("'", "'\\''") .. "'"):read("*l") or ""
package.path = (self:match("^(.*)/[^/]*$") or ".") .. "/../lib/serverstick/?.lua;" .. package.path

local sys = require("sys")
local q, run, quiet, capture = sys.q, sys.run, sys.quiet, sys.capture

local AUTHKEY_FILE = "/etc/tailscale/authkey"
local SOCKET = "/run/tailscale/tailscaled.sock"
local CONTROL_HOST = "controlplane.tailscale.com"
local function env(name, default)
  local v = os.getenv(name)
  return (v and v ~= "") and v or default
end
local TS_HOSTNAME = env("TS_HOSTNAME", "stickserver")
local SOCKET_TIMEOUT = tonumber(env("SOCKET_TIMEOUT", "90"))
local NET_TIMEOUT = tonumber(env("NET_TIMEOUT", "300"))
local CLOCK_TIMEOUT = tonumber(env("CLOCK_TIMEOUT", "30"))
local MAX_ATTEMPTS = tonumber(env("MAX_ATTEMPTS", "8"))

-- "<N>" prefixes set the journal priority (3=err, 4=warning, 5=notice, 6=info).
local function say(prio, msg)
  for line in (msg .. "\n"):gmatch("([^\n]*)\n") do io.stdout:write("<", prio, ">", line, "\n") end
end
local function info(m) say(6, m) end
local function note(m) say(5, m) end
local function warn(m) say(4, m) end
local function err(m) say(3, m) end

-- Command output, every line indented and logged at info level.
local function dump(cmd, indent)
  local out = capture(cmd .. " 2>&1")
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    if line ~= "" then info(indent .. line) end
  end
end

local function dump_network()
  info("  ip addr:")
  dump("ip -br addr", "    ")
  info("  routes:")
  dump("ip route", "    ")
  info("  dns:")
  dump("resolvectl dns", "    ")
end

local function backend_state()
  local json = capture("tailscale status --json 2>/dev/null")
  return json:match('"BackendState":%s*"([^"]*)"') or ""
end

local function clock_synced()
  return capture("timedatectl show -p NTPSynchronized --value 2>/dev/null") == "yes"
end

local function utc_now()
  return os.date("!%Y-%m-%d %H:%M:%S UTC")
end

local function main()
  note("step 0/4: checking config (hostname=" .. TS_HOSTNAME .. ")")
  local key = sys.read(AUTHKEY_FILE)
  if not key or key == "" then
    err("auth key file " .. AUTHKEY_FILE .. " is missing or empty; rebuild the ISO with TS_AUTHKEY in .env")
    return 1
  end
  if key:sub(1, 6) ~= "tskey-" then
    err("auth key in " .. AUTHKEY_FILE .. " does not start with 'tskey-'")
    return 1
  end
  info("auth key file present (" .. capture("stat -c '%a %U' " .. q(AUTHKEY_FILE)) .. ")")

  note("step 1/4: waiting for tailscaled socket " .. SOCKET .. " (timeout " .. SOCKET_TIMEOUT .. "s)")
  local up = false
  for _ = 1, SOCKET_TIMEOUT do
    if run("test -S " .. q(SOCKET)) and quiet("tailscale status --json") then
      up = true
      break
    end
    sys.sleep(1)
  end
  if not up and not run("test -S " .. q(SOCKET)) then
    err("tailscaled socket did not appear after " .. SOCKET_TIMEOUT .. "s; check: journalctl -u tailscaled")
    return 1
  end
  local state = backend_state()
  info("tailscaled is up, backend state: " .. (state ~= "" and state or "unknown"))
  if state == "Running" then
    note("already joined, nothing to do")
    dump("tailscale status | head -n 5", "  ")
    return 0
  end

  note("step 2/4: waiting for network (resolve " .. CONTROL_HOST .. ", timeout " .. NET_TIMEOUT .. "s)")
  local start, last_log = sys.now(), -30
  while not quiet("getent ahosts " .. CONTROL_HOST) do
    local elapsed = math.floor(sys.now() - start)
    if elapsed >= NET_TIMEOUT then
      err("cannot resolve " .. CONTROL_HOST .. " after " .. NET_TIMEOUT .. "s: no usable network/DNS")
      dump_network()
      return 1
    end
    if elapsed - last_log >= 30 then
      last_log = elapsed
      info("still waiting for network (" .. elapsed .. "s)")
      dump("ip -br addr | grep -v '^lo '", "    ")
    end
    sys.sleep(2)
  end
  info(CONTROL_HOST .. " resolves to: "
    .. capture("getent ahosts " .. CONTROL_HOST .. " | awk '{print $1}' | sort -u | tr '\\n' ' '"))
  dump_network()

  -- A wrong clock breaks TLS. Give timesyncd a moment, but don't block on it.
  for _ = 1, CLOCK_TIMEOUT do
    if clock_synced() then break end
    sys.sleep(1)
  end
  if clock_synced() then
    info("clock synchronized: " .. utc_now())
  else
    warn("clock NOT synchronized yet after " .. CLOCK_TIMEOUT .. "s (now " .. utc_now() .. "); TLS may fail if it is far off")
  end

  note("step 3/4: tailscale up (max " .. MAX_ATTEMPTS .. " attempts)")
  local cmd = "tailscale up --auth-key=file:" .. AUTHKEY_FILE .. " --ssh --hostname=" .. q(TS_HOSTNAME) .. " --timeout=60s"
  local delay = 5
  for attempt = 1, MAX_ATTEMPTS do
    info("attempt " .. attempt .. "/" .. MAX_ATTEMPTS .. ": tailscale up --auth-key=file:" .. AUTHKEY_FILE
      .. " --ssh --hostname=" .. TS_HOSTNAME)
    local out, ok = capture(cmd .. " 2>&1")
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do
      if line ~= "" then info("  | " .. line) end
    end
    if ok then break end
    warn("tailscale up failed")
    local low = out:lower()
    if low:find("invalid") and low:find("key") or low:find("expired") or low:find("not valid") then
      warn("hint: the auth key looks invalid/expired/used-up; create a new reusable key and rebuild")
    elseif low:find("tagowners") or low:find("tags") then
      warn("hint: tagged key needs tagOwners in the tailnet policy (see README)")
    elseif low:find("x509") or low:find("certificate") then
      warn("hint: TLS error; check the clock: " .. utc_now())
    end
    if attempt == MAX_ATTEMPTS then
      err("giving up after " .. MAX_ATTEMPTS .. " attempts (systemd will restart this unit)")
      return 1
    end
    info("retrying in " .. delay .. "s")
    sys.sleep(delay)
    delay = math.min(delay * 2, 60)
  end

  note("step 4/4: joined")
  info("tailscale IPs: " .. capture("tailscale ip 2>/dev/null | tr '\\n' ' '"))
  dump("tailscale status | head -n 10", "  ")
  -- The tailnet may hand out "<name>-1" if an old node with the same name still exists.
  local json = capture("tailscale status --json 2>/dev/null")
  local self_block = json:match('"Self"%s*:%s*(%b{})') or ""
  local name = (self_block:match('"DNSName"%s*:%s*"([^".]*)') or "")
  if name ~= "" and name:lower() ~= TS_HOSTNAME:lower() then
    warn("tailnet name is '" .. name .. "' (not '" .. TS_HOSTNAME .. "'): an older node with that name still exists")
  end
  note("done: connect with ssh root@" .. (name ~= "" and name or TS_HOSTNAME))
  return 0
end

os.exit(main())
