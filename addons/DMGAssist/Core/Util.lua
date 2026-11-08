-- Util.lua: secret-safe helpers (same contract as the Watchdog's U module).
local _, ns = ...

local U = {}
ns.U = U
ns.VERSION = "0.1.0"
ns.SECRET = "<secret>"

local issecretvalue, pcall, type, select = issecretvalue, pcall, type, select

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

function U.Print(fmt, ...)
  local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
  print("|cffffb000[DMGAssist]|r " .. msg)
end

-- Send a line to DMGAssist_Watchdog if it is installed (it records it into the current combat session).
function U.Log(kind, data)
  local wd = DMGAssistWatchdog
  if type(wd) == "table" and type(wd.Log) == "function" then
    pcall(wd.Log, kind, data)
  end
end
