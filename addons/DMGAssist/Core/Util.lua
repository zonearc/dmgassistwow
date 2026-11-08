-- Util.lua: secret-safe helpers (same contract as the Watchdog's U module).
local _, ns = ...

local U = {}
ns.U = U
ns.VERSION = "1.6.0"
-- Testing build: extra logging and chat notices while we test with players. Set to false for a release.
ns.TESTING = false
ns.SECRET = "<secret>"

local issecretvalue, pcall, type, select, unpack = issecretvalue, pcall, type, select, unpack

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

function U.Safe(v)
  if v == nil then
    return nil
  end
  if U.IsSecret(v) then
    return ns.SECRET
  end
  local t = type(v)
  if t == "number" or t == "boolean" or t == "string" then
    return v
  end
  return "<" .. t .. ">"
end

local function Pack(...)
  return { n = select("#", ...), ... }
end

-- pcall + Safe on every return. Returns a table { ok, n, ... } or { ok = false, err }.
function U.Try(fn, ...)
  if type(fn) ~= "function" then
    return { ok = false, err = "missing" }
  end
  local packed = Pack(pcall(fn, ...))
  if not packed[1] then
    return { ok = false, err = U.Safe(packed[2]) }
  end
  local out = { ok = true, n = packed.n - 1 }
  for i = 2, packed.n do
    out[i - 1] = U.Safe(packed[i])
  end
  return out
end

-- The value itself when readable (any type); nil when it is secret. Use before comparing or indexing.
function U.Read(v)
  if v == nil or U.IsSecret(v) then
    return nil
  end
  return v
end

-- Call fn and return its results unchanged (they may be secret: pass them through U.Read).
-- Returns nothing when fn is missing or raised an error.
-- Failed calls are counted by message (U.callErrors) and the first of each kind is logged, so a call that starts
-- failing in combat ("went dark") shows up in the Watchdog log instead of silently returning nothing.
U.callErrors = {}
local callErrorKinds = 0

function U.Call(fn, ...)
  if type(fn) ~= "function" then
    return nil
  end
  local p = Pack(pcall(fn, ...))
  if not p[1] then
    local msg = U.Safe(p[2])
    msg = type(msg) == "string" and msg:gsub("^.-AddOns\\", ""):sub(1, 160) or tostring(msg)
    local n = U.callErrors[msg]
    if not n and callErrorKinds < 50 then
      callErrorKinds = callErrorKinds + 1
      U.callErrors[msg] = 1
      U.Log("call_error", msg)
    elseif n then
      U.callErrors[msg] = n + 1
    end
    return nil
  end
  return unpack(p, 2, p.n)
end

-- Call fn and return its first result if readable; nil if it is secret, fn is missing, or the call failed.
-- The everyday way to ask the game something: U.Get(UnitPower, "player", 4).
function U.Get(fn, ...)
  return U.Read((U.Call(fn, ...)))
end

-- "buff.tigers_fury.up" -> { "buff", "tigers_fury", "up" }
function U.SplitDots(name)
  local parts = {}
  for part in name:gmatch("[^%.]+") do
    parts[#parts + 1] = part
  end
  return parts
end

function U.Print(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  print("|cffffb000[DMGAssist]|r " .. msg)
end

-- Send a line to DMGAssist_Watchdog if it is installed (it records it into the current combat session).
-- Tables are flattened to "k=v k=v" (sorted keys, one level, secret-safe) so the Watchdog stores them as text.
local function Flatten(data)
  if type(data) ~= "table" then
    return data
  end
  local keys = {}
  for k in pairs(data) do
    keys[#keys + 1] = tostring(k)
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = data[k]
    if v == nil then
      v = data[tonumber(k)]
    end
    if type(v) == "table" then
      local inner = {}
      for ik, iv in pairs(v) do
        inner[#inner + 1] = tostring(U.Safe(ik)) .. ":" .. tostring(U.Safe(iv))
      end
      table.sort(inner)
      v = "{" .. table.concat(inner, ",") .. "}"
    else
      v = tostring(U.Safe(v))
    end
    parts[#parts + 1] = k .. "=" .. v
  end
  return table.concat(parts, " ")
end
U.Flatten = Flatten

function U.Log(kind, data)
  local wd = DMGAssistWatchdog
  if type(wd) == "table" and type(wd.Log) == "function" then
    pcall(wd.Log, kind, Flatten(data))
  end
end
