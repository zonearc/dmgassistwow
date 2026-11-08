-- Util.lua: secret-safe helpers shared by every Watchdog file.
--
-- Rule for this addon: no value that came from a game API is compared,
-- tested for truthiness, used in arithmetic, or used as a table key until it
-- has gone through U.Safe() or U.IsSecret(). See docs/reference/api-findings.md.

local _, ns = ...

local U = {}
ns.U = U

local type, pcall, select, tostring = type, pcall, select, tostring
local string_sub, string_format = string.sub, string.format
local issecretvalue = issecretvalue
local GetTime = GetTime

ns.VERSION = "0.1.0"
ns.SECRET = "<secret>"
ns.MAX_STRING = 400

-- True if v is a secret value (or if we cannot even ask). Never errors.
function U.IsSecret(v)
  if issecretvalue == nil then
    return false
  end
  local ok, res = pcall(issecretvalue, v)
  if not ok then
    return true
  end
  return res == true
end

-- Convert any value into something safe to store in SavedVariables and to
-- compare in Lua: secrets become ns.SECRET, strings are truncated, tables and
-- functions become a type tag.
function U.Safe(v, maxLen)
  if v == nil then
    return nil
  end
  if U.IsSecret(v) then
    return ns.SECRET
  end
  local t = type(v)
  if t == "number" or t == "boolean" then
    return v
  elseif t == "string" then
    local limit = maxLen or ns.MAX_STRING
    if #v > limit then
      return string_sub(v, 1, limit) .. "..."
    end
    return v
  end
  return "<" .. t .. ">"
end

-- Pack varargs, keeping the count (Lua 5.1 has no table.pack).
function U.Pack(...)
  return { n = select("#", ...), ... }
end

-- Call fn safely. Returns a table: { ok = bool, n = count, [1..n] = safe values }
-- or { ok = false, err = message } if the call errored or fn is missing.
function U.Try(fn, ...)
  if type(fn) ~= "function" then
    return { ok = false, err = "missing" }
  end
  local r = U.Pack(pcall(fn, ...))
  if not r[1] then
    return { ok = false, err = U.Safe(r[2]) }
  end
  local out = { ok = true, n = r.n - 1 }
  for i = 2, r.n do
    out[i - 1] = U.Safe(r[i])
  end
  return out
end

-- Look up a dotted global path ("C_Spell.GetSpellCooldown") without erroring.
function U.Resolve(path)
  local node = _G
  for part in string.gmatch(path, "[^%.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[part]
  end
  return node
end

function U.Now()
  return GetTime()
end

-- Seconds with two decimals, as a number.
function U.Round2(x)
  if type(x) ~= "number" then
    return x
  end
  return math.floor(x * 100 + 0.5) / 100
end

-- Short human readable summary of a U.Try result, used by the viewer.
function U.Describe(res)
  if not res then
    return "nil"
  end
  if not res.ok then
    return "error: " .. tostring(res.err)
  end
  local parts = {}
  for i = 1, res.n do
    parts[#parts + 1] = tostring(res[i])
  end
  return table.concat(parts, ", ")
end

function U.Print(fmt, ...)
  local msg = select("#", ...) > 0 and string_format(fmt, ...) or fmt
  print("|cff33ccff[DMGA Watchdog]|r " .. msg)
end
