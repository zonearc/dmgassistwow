-- Record.lua: everything the game told DMGAssist, so a real fight can be replayed offline (owner, 2026-11-16: "design
-- ahead of time to make it easy and robust what I can export from the game so you have literally everything you
-- need").
--
-- Every question DMGAssist asks the game goes through U.Call / U.Get (Util.lua). While recording, each answer is
-- noted by question - "UnitPower(player,3)", "C_Spell.IsSpellUsable(5221)" - and written only when it changes, with
-- the time. The events the addon handles are written too. tools/replay.py feeds them back to the addon offline:
-- the same fight, decided again by any version of the code, and graded against the presses really made.
--
-- Lines (DMGAssistWatchdog.Record, kept per fight beside the decision log):
--   K <id> <question>             a question's short id (once per fight)
--   T <time>|<id>=<answer>;...    the answers that changed at that time (seconds since the fight began)
--   E <time>|<event>|<args>       an event the addon handled
--   H <field>=<value>;...         the fight's header: spec, talents, haste, version, client
-- Answers: numbers, T / F, "text", - (nil), S (secret: the game hid it), {k:v,...} for small tables.

local _, ns = ...
local U = ns.U

local R = { on = false }
ns.Record = R

R.MAX_KEYS = 4000

local names -- function -> "Name" / "C_Spell.Name"
local keyId, last, nextId, pending, start = {}, {}, 0, {}, nil

local function BuildNames()
  names = setmetatable({}, { __mode = "k" })
  for k, v in pairs(_G) do
    if type(k) == "string" then
      if type(v) == "function" then
        names[v] = names[v] or k
      elseif type(v) == "table" and k:match("^C_%u") then
        for k2, v2 in pairs(v) do
          if type(k2) == "string" and type(v2) == "function" then
            names[v2] = names[v2] or (k .. "." .. k2)
          end
        end
      end
    end
  end
end

local function Enc(v, depth)
  if v == nil then
    return "-"
  end
  if U.IsSecret(v) then
    return "S"
  end
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e12 then
      return string.format("%d", v)
    end
    return string.format("%.3f", v)
  elseif t == "boolean" then
    return v and "T" or "F"
  elseif t == "string" then
    return '"' .. v:gsub("[;|\n\"]", " "):sub(1, 40) .. '"'
  elseif t == "table" and (depth or 0) < 1 then
    local keys = {}
    for k in pairs(v) do
      if type(k) == "string" or type(k) == "number" then
        keys[#keys + 1] = k
      end
    end
    table.sort(keys, function(a, b)
      return tostring(a) < tostring(b)
    end)
    local parts = {}
    for i, k in ipairs(keys) do
      if i > 12 then
        break
      end
      local item = v[k]
      if type(item) ~= "function" and type(item) ~= "userdata" then
        parts[#parts + 1] = tostring(k) .. ":" .. Enc(item, (depth or 0) + 1)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "?"
end
R.Enc = Enc

-- (lines before the Watchdog has opened the fight wait here: both start on the same combat event, in either order)
local early = {}
local function Write(line)
  local wd = DMGAssistWatchdog
  if type(wd) ~= "table" or type(wd.Record) ~= "function" then
    return false
  end
  if #early > 0 then
    local ok, stored = pcall(wd.Record, early[1])
    if not (ok and stored) then
      if #early < 400 then
        early[#early + 1] = line
      end
      return false
    end
    for i = 2, #early do
      pcall(wd.Record, early[i])
    end
    early = {}
  end
  local ok, stored = pcall(wd.Record, line)
  if not (ok and stored) and start and #early < 400 then
    early[#early + 1] = line
  end
  return ok and stored
end

-- The question's text: "UnitPower("player",3)" (also used by the replay to look the answer up)
function R.Key(fn, args)
  if not names then
    BuildNames()
  end
  local name = names[fn]
  if not name then
    return nil
  end
  local a = {}
  for i = 1, args.n or #args do
    a[i] = Enc(args[i], 1)
  end
  return name .. "(" .. table.concat(a, ",") .. ")"
end

-- U.Call's hook: one question and its answers
function R.Note(fn, args, n, results)
  if not R.on then
    return
  end
  -- (UI objects aren't answers about the fight: frames, buttons - a replayed copy would have no methods)
  for i = 1, n or 0 do
    local v = results[i]
    if type(v) == "table" and not U.IsSecret(v) then
      if getmetatable(v) ~= nil or rawget(v, 0) ~= nil then
        return
      end
      for _, item in pairs(v) do
        if type(item) == "function" then
          return
        end
      end
    end
  end
  local key = R.Key(fn, args)
  if not key then
    return
  end
  local id = keyId[key]
  if not id then
    if nextId >= R.MAX_KEYS then
      return
    end
    nextId = nextId + 1
    id = nextId
    keyId[key] = id
    Write("K " .. id .. " " .. key)
  end
  local out = {}
  for i = 1, math.max(1, n or 0) do
    out[i] = Enc(results[i])
  end
  local val = table.concat(out, ",")
  if last[id] ~= val then
    last[id] = val
    pending[#pending + 1] = id .. "=" .. val
  end
end

local function Now()
  return start and (GetTime() - start) or 0
end

-- written at the end of every decision pass (State.EndPass) and before each event
function R.Flush()
  if #pending > 0 then
    Write(string.format("T %.2f|%s", Now(), table.concat(pending, ";")))
    pending = {}
  end
end

function R.Event(event, ...)
  if not R.on or not start then
    return
  end
  R.Flush()
  local a = { n = select("#", ...), ... }
  local parts = {}
  for i = 1, math.min(a.n, 6) do
    parts[i] = Enc(a[i], 1)
  end
  Write(string.format("E %.2f|%s|%s", Now(), tostring(event), table.concat(parts, ",")))
end

-- A fight begins: every question gets asked anew (the replay of one fight needs no other), the header goes first.
function R.Begin()
  if not R.Enabled() then
    R.on = false
    return
  end
  if not names then
    BuildNames()
  end
  keyId, last, nextId, pending = {}, {}, 0, {}
  start = GetTime()
  early = {}
  local state = ns.Specs and ns.Specs.current
  -- the talents exactly: the game's own loadout string (import it to see the build)
  local config = C_ClassTalents and U.Get(C_ClassTalents.GetActiveConfigID)
  local loadout = config and C_Traits and U.Get(C_Traits.GenerateImportString, config)
  local build = GetBuildInfo and select(2, GetBuildInfo())
  Write(string.format("H version=%s;spec=%s;client=%s;start=%.2f;haste=%s;loadout=%s", tostring(ns.VERSION or "?"),
    tostring(state and state.key or "?"), tostring(build or "?"), start,
    Enc(U.Get(UnitSpellHaste, "player")), tostring(loadout or "?")))
  -- what DMGAssist read out of combat and keeps: the spellbook (and swapped buttons), the talents, your settings
  local M = ns.SpellMap
  local book = {}
  for id, b in pairs(M and M.book or {}) do
    if type(id) == "number" and type(b) == "table" then
      book[#book + 1] = id .. ":" .. tostring(b.id or id) .. ":" .. (b.passive and "p" or "") .. ":" ..
        tostring(M.baseOf and M.baseOf[id] or "")
    end
  end
  table.sort(book)
  Write("B " .. table.concat(book, ","))
  local tal = {}
  for id, r in pairs(M and M.talentIDs or {}) do
    tal[#tal + 1] = id .. ":" .. tostring(r)
  end
  table.sort(tal)
  local tok = {}
  for k, r in pairs(M and M.talents or {}) do
    tok[#tok + 1] = tostring(k) .. ":" .. tostring(r)
  end
  table.sort(tok)
  Write("TAL " .. table.concat(tal, ",") .. "|" .. table.concat(tok, ","))
  local set = {}
  for k, v in pairs(type(ns.db) == "table" and ns.db or {}) do
    local tv = type(v)
    if type(k) == "string" and (tv == "number" or tv == "boolean" or tv == "string") then
      set[#set + 1] = k .. "=" .. Enc(v)
    end
  end
  table.sort(set)
  Write("D " .. table.concat(set, ";"))
  R.on = true
end

function R.End()
  R.Flush()
  R.on = false
  start = nil
end

function R.Enabled()
  local db = ns.db
  return type(db) == "table" and db.recordInputs == true
end

function R.Set(on)
  if type(ns.db) == "table" then
    ns.db.recordInputs = on and true or nil
  end
end

return R
