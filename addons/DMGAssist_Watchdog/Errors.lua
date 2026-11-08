-- Errors.lua: capture Lua errors and blocked/forbidden actions.
--
-- Blizzard's own AddLuaErrorHandler() asserts issecure(), so addons cannot use
-- it. Instead we chain onto the global handler (the same approach BugGrabber
-- uses): record the error, then pass it on to whatever handler was there
-- before so the default error UI keeps working.
--
-- The handler is installed when this file loads, before SavedVariables exist,
-- so load-time errors from other addons are caught. They are buffered in
-- `pending` and moved into the database on ADDON_LOADED.

local _, ns = ...
local U, S = ns.U, ns.Store

local E = {}
ns.Errors = E

local pending = {}
local byKey = {}       -- dedupe key -> entry, rebuilt on ADDON_LOADED
local previousHandler
local inHandler = false
local MAX_STACK = 1500

local debugstack, geterrorhandler, seterrorhandler = debugstack, geterrorhandler, seterrorhandler

local function Store(entry)
  local db = ns.db
  if not db then
    pending[#pending + 1] = entry
    return
  end
  local existing = byKey[entry.key]
  if existing then
    existing.count = existing.count + 1
    existing.lastT = entry.firstT
    existing.lastWhen = entry.firstWhen
    return
  end
  byKey[entry.key] = entry
  S.Push(db.errors, entry, db.settings.maxErrors)
  S.Count("errors")
end

-- kind: "lua", "blocked", "forbidden", "warning", "macro_blocked", ...
function E.Record(kind, message, stack)
  local msg = U.Safe(message, 600) or "<nil>"
  local stk = U.Safe(stack, MAX_STACK)
  local ours = false
  if type(msg) == "string" and string.find(msg, "DMGAssist", 1, true) then
    ours = true
  elseif type(stk) == "string" and string.find(stk, "DMGAssist", 1, true) then
    ours = true
  end
  local entry = {
    kind = kind,
    msg = msg,
    stack = stk,
    ours = ours,
    count = 1,
    firstT = U.Round2(U.Now()),
    firstWhen = date("%Y-%m-%d %H:%M:%S"),
    inCombat = ns.Sessions and ns.Sessions.Active() and true or false,
    key = kind .. ":" .. (type(msg) == "string" and string.sub(msg, 1, 300) or "?"),
  }
  entry.lastT, entry.lastWhen = entry.firstT, entry.firstWhen
  Store(entry)
  if ns.Sessions then
    ns.Sessions.Add("E", kind, type(msg) == "string" and string.sub(msg, 1, 160) or msg)
  end
end

local function OnLuaError(message)
  if not inHandler then
    inHandler = true
    local stack = debugstack and debugstack(3) or nil
    pcall(E.Record, "lua", message, stack)
    inHandler = false
  end
  if previousHandler then
    return previousHandler(message)
  end
end

-- (Re)install our handler on top of whatever is current. Safe to call often:
-- if another addon or Blizzard replaced the handler, we chain onto theirs.
function E.Install()
  if not (ns.db == nil or ns.db.settings.captureErrors) then
    return
  end
  if not (geterrorhandler and seterrorhandler) then
    return
  end
  local current = geterrorhandler()
  if current == OnLuaError then
    return
  end
  previousHandler = current
  seterrorhandler(OnLuaError)
end

function E.IsInstalled()
  return geterrorhandler and geterrorhandler() == OnLuaError
end

-- Called on our ADDON_LOADED: rebuild the dedupe index, flush pending.
function E.OnDatabaseReady()
  byKey = {}
  for _, entry in ipairs(ns.db.errors) do
    if entry.key then
      byKey[entry.key] = entry
    end
  end
  for i = 1, #pending do
    Store(pending[i])
  end
  pending = {}
end

function E.HandleEvent(event, arg1, arg2)
  if event == "ADDON_ACTION_BLOCKED" then
    E.Record("blocked", "tainted=" .. tostring(U.Safe(arg1)) .. " function=" .. tostring(U.Safe(arg2)),
      debugstack and debugstack(2) or nil)
  elseif event == "ADDON_ACTION_FORBIDDEN" then
    E.Record("forbidden", "tainted=" .. tostring(U.Safe(arg1)) .. " function=" .. tostring(U.Safe(arg2)),
      debugstack and debugstack(2) or nil)
  elseif event == "MACRO_ACTION_BLOCKED" or event == "MACRO_ACTION_FORBIDDEN" then
    E.Record(string.lower(event), "function=" .. tostring(U.Safe(arg1)))
  elseif event == "LUA_WARNING" then
    E.Record("warning", arg1)
  elseif event == "SAVED_VARIABLES_TOO_LARGE" then
    E.Record("savedvars_too_large", "addon=" .. tostring(U.Safe(arg1)))
  end
end

E.EVENTS = {
  "ADDON_ACTION_BLOCKED",
  "ADDON_ACTION_FORBIDDEN",
  "MACRO_ACTION_BLOCKED",
  "MACRO_ACTION_FORBIDDEN",
  "LUA_WARNING",
  "SAVED_VARIABLES_TOO_LARGE",
}

-- Install immediately at file load.
E.Install()
