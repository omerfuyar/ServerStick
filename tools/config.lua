-- Reads .env and packages.txt, applies defaults, and validates everything up front.

local util = require("util")

local M = {}

M.DEFAULTS = {
  TS_HOSTNAME = "stickserver",
  EXTRA_PACKAGES = "",
  COW_SPACESIZE = "50%",
  WIFI_SSID = "",
  WIFI_PASSWORD = "",
  NET_FALLBACK = "1",
  ROOT_PASSWORD = "",
}

-- Parse a .env file: KEY=value, KEY="value", KEY='value', optional "export ",
-- blank lines and # comments. Unquoted values end at " #".
function M.parse_env(path)
  local text = util.read(path)
  if not text then return nil end
  local env = {}
  local n = 0
  for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
    n = n + 1
    local body = raw:gsub("\r$", ""):match("^%s*(.-)%s*$")
    if body ~= "" and body:sub(1, 1) ~= "#" then
      body = body:gsub("^export%s+", "")
      local key, value = body:match("^([%a_][%w_]*)%s*=%s*(.*)$")
      if not key then
        util.die(path .. ":" .. n .. ": expected KEY=value")
      end
      local quote = value:sub(1, 1)
      if quote == '"' or quote == "'" then
        local inner = value:match("^" .. quote .. "(.*)" .. quote)
        if not inner then
          util.die(path .. ":" .. n .. ": missing closing " .. quote .. " for " .. key)
        end
        value = inner
      else
        value = value:gsub("%s+#.*$", "")
      end
      env[key] = value
    end
  end
  return env
end

-- Packages from packages.txt: one per line, '#' starts a comment.
function M.packages(root)
  local text = util.read(root .. "/packages.txt")
  if not text then util.die("packages.txt not found") end
  local list = {}
  for line in text:gmatch("[^\n]+") do
    local name = line:gsub("#.*$", ""):match("^%s*(%S+)%s*$")
    if name then list[#list + 1] = name end
  end
  return list
end

-- Load .env with defaults. Without `strict`, a missing .env just gives the defaults
-- (verify only needs the non-secret values).
function M.load(root, strict)
  local env = M.parse_env(root .. "/.env")
  if not env then
    if strict then util.die(".env not found. Run: cp .env.example .env  and set TS_AUTHKEY") end
    env = {}
  end
  for k, v in pairs(M.DEFAULTS) do
    if env[k] == nil or env[k] == "" then env[k] = v end
  end
  env.TS_AUTHKEY = env.TS_AUTHKEY or ""
  env.EXTRA = util.words(env.EXTRA_PACKAGES)
  return env
end

-- Fail early with a clear message for anything the build can't use.
function M.validate(env)
  local key = env.TS_AUTHKEY
  if key == "" then util.die("TS_AUTHKEY is missing in .env") end
  if key:sub(1, 6) ~= "tskey-" then
    util.die("TS_AUTHKEY must start with 'tskey-' (got '" .. key:sub(1, 6) .. "...')")
  end
  if key:find("REPLACE-ME", 1, true) then util.die("TS_AUTHKEY is still the placeholder from .env.example") end
  if not key:match("^[%w_-]+$") then util.die("TS_AUTHKEY contains unexpected characters (spaces/quotes?)") end

  local host = env.TS_HOSTNAME
  if #host > 63 or not host:match("^%w[%w-]*$") or host:sub(-1) == "-" then
    util.die("TS_HOSTNAME '" .. host .. "' is not a valid hostname (letters, digits, '-', max 63)")
  end

  for _, p in ipairs(env.EXTRA) do
    if not p:match("^[a-z0-9@._+-]+$") then util.die("EXTRA_PACKAGES: invalid package name '" .. p .. "'") end
  end

  local ssid, psk = env.WIFI_SSID, env.WIFI_PASSWORD
  if ssid ~= "" or psk ~= "" then
    if ssid == "" or psk == "" then util.die("set both WIFI_SSID and WIFI_PASSWORD, or neither") end
    if #psk < 8 or #psk > 63 then util.die("WIFI_PASSWORD must be 8-63 characters") end
    if #ssid > 32 then util.die("WIFI_SSID must be at most 32 bytes") end
  end

  if env.NET_FALLBACK ~= "0" and env.NET_FALLBACK ~= "1" then util.die("NET_FALLBACK must be 1 or 0") end

  local cow = env.COW_SPACESIZE
  local pct = cow:match("^(%d+)%%$")
  local ok = (pct and tonumber(pct) >= 1 and tonumber(pct) <= 100 and pct:sub(1, 1) ~= "0")
    or (cow:match("^[1-9]%d*[KMG]$") ~= nil)
  if not ok then
    util.die("COW_SPACESIZE '" .. cow .. "' must be a percentage of RAM (1%-100%) or a size like 512M / 8G")
  end

  if env.ROOT_PASSWORD:find("[\n\r]") then util.die("ROOT_PASSWORD must not contain newlines") end
end

return M
