-- Replay a recorded fight (Core/Record.lua) through the current addon, offline.
--   lua5.1 tests/replay.lua <input.lua>     (written by tools/replay.py from a Watchdog export)
-- The game's recorded answers are given back to every question the addon asks (U.Call), the recorded events are
-- fired at their times, a decision pass runs at each recorded pass. Prints, as lines tools/replay.py reads:
--   SAME <slot1 agreement %> <slot2 agreement %> <passes>   - replayed picks vs the ones shown in game
--   REAL <slot2 right %> <presses>                           - slot 2 vs the press that really came next
--   PICK <t> <slot1 id> <slot2 id>                           - each replayed pass (with --picks)
package.path = "./tests/?.lua;" .. package.path
local mock = require("wow_mock")
local print = print
mock.Install(_G)

local input = dofile(arg[1])
local showPicks = arg[2] == "--picks"

mock.frames, mock.timers, mock.printed = {}, {}, {}
mock.restricted, mock.inCombat, mock.hasTarget = false, false, true
mock.gameType = "standard"
WOW_PROJECT_ID = 1
DMGAssistDB = nil
local ns = mock.LoadAddon("addons/DMGAssist", "DMGAssist")
mock.Fire("ADDON_LOADED", "DMGAssist")
mock.Fire("PLAYER_LOGIN")
local M, S, R = ns.SpellMap, ns.State, ns.Record

-- the character: spec data, spellbook, talents, settings as recorded
local key = input.spec
local record = ns.Data.specs.midnight[key]
assert(record, "no data for spec " .. tostring(key))
ns.Specs.current = ns.Specs.current or {}
ns.Specs.current.key, ns.Specs.current.branch, ns.Specs.current.data = key, "midnight", record
M.SetData(record)
M.book, M.baseOf = {}, {}
for _, b in ipairs(input.book) do
  M.book[b[1]] = { id = b[2], passive = b[3] }
  if b[4] then
    M.baseOf[b[1]] = b[4]
  end
end
M.talentIDs, M.talents, M.talentsRead = input.talentIDs, input.talents, true
M.Refresh = function() end -- (keep the recorded book)
S.Bind(key)
for k, v in pairs(input.settings) do
  ns.db[k] = v
end

-- answers
local function Dec(s)
  if s == "-" then
    return nil
  elseif s == "S" then
    return mock.Secret()
  elseif s == "T" then
    return true
  elseif s == "F" then
    return false
  elseif s:sub(1, 1) == '"' then
    return s:sub(2, -2)
  elseif s:sub(1, 1) == "{" then
    local t = {}
    local body = s:sub(2, -2)
    local depth, cur = 0, ""
    local items = {}
    for ch in body:gmatch(".") do
      if ch == "{" then depth = depth + 1 elseif ch == "}" then depth = depth - 1 end
      if ch == "," and depth == 0 then
        items[#items + 1] = cur
        cur = ""
      else
        cur = cur .. ch
      end
    end
    if cur ~= "" then
      items[#items + 1] = cur
    end
    for _, it in ipairs(items) do
      local k, v = it:match("^([^:]+):(.*)$")
      if k then
        t[tonumber(k) or k] = Dec(v)
      end
    end
    return t
  end
  return tonumber(s) or s
end
local function Split(s)
  local out, depth, cur = {}, 0, ""
  for ch in s:gmatch(".") do
    if ch == "{" then depth = depth + 1 elseif ch == "}" then depth = depth - 1 end
    if ch == "," and depth == 0 then
      out[#out + 1] = cur
      cur = ""
    else
      cur = cur .. ch
    end
  end
  out[#out + 1] = cur
  return out
end

local keys, answer = {}, {} -- id -> question; question -> packed answer
R.replay = function(fn, ...)
  local k = R.Key(fn, { n = select("#", ...), ... })
  local a = k and answer[k]
  if a then
    return true, a
  end
  return false
end

local function Apply(updates)
  for item in updates:gmatch("[^;]+") do
    local id, val = item:match("^(%d+)=(.*)$")
    local q = id and keys[tonumber(id)]
    if q then
      local parts = Split(val)
      local packed = { n = #parts }
      for i, p in ipairs(parts) do
        packed[i] = Dec(p)
      end
      answer[q] = packed
    end
  end
end

-- the fight
local t0 = mock.now
local picks, presses = {}, {}
mock.inCombat, mock.restricted = true, true
for _, line in ipairs(input.lines) do
  local kind = line:sub(1, 1)
  if kind == "K" then
    local id, q = line:match("^K (%d+) (.*)$")
    keys[tonumber(id)] = q
  elseif kind == "T" then
    local t, updates = line:match("^T ([%d.]+)|(.*)$")
    mock.now = t0 + tonumber(t)
    Apply(updates)
    local ok, r = pcall(ns.Update)
    if ok and r and r.main then
      local q2 = r.queue and r.queue[2]
      picks[#picks + 1] = { t = tonumber(t), s1 = r.main.id, s2 = q2 and q2.id or nil }
      if showPicks then
        print(string.format("PICK %.2f %s %s", tonumber(t), tostring(r.main.id), tostring(q2 and q2.id)))
      end
    end
  elseif kind == "E" then
    local t, ev, args = line:match("^E ([%d.]+)|([%w_]+)|(.*)$")
    if t then
      mock.now = t0 + tonumber(t)
      local a = {}
      for i, p in ipairs(args ~= "" and Split(args) or {}) do
        a[i] = Dec(p)
      end
      if ev == "PLAYER_REGEN_ENABLED" then
        mock.inCombat, mock.restricted = false, false
      end
      if ev == "UNIT_SPELLCAST_SUCCEEDED" and a[1] == "player" then
        presses[#presses + 1] = { t = tonumber(t), id = a[3] }
      end
      pcall(mock.Fire, ev, a[1], a[2], a[3], a[4], a[5], a[6])
    end
  end
end

-- vs the picks shown in game (logged "pick" lines: main=token next=token, by time)
local same1, same2, n = 0, 0, 0
for _, g in ipairs(input.shown or {}) do
  local best
  for _, p in ipairs(picks) do
    if p.t <= g.t + 0.05 then
      best = p
    else
      break
    end
  end
  if best then
    n = n + 1
    local t1 = M.TokenForID(best.s1)
    local t2 = best.s2 and M.TokenForID(best.s2)
    if t1 == g.main then
      same1 = same1 + 1
    end
    if t2 == g.next then
      same2 = same2 + 1
    end
  end
end
print(string.format("SAME %.1f %.1f %d", n > 0 and 100 * same1 / n or 0, n > 0 and 100 * same2 / n or 0, n))

-- slot 2 vs the press that came next (only after a press of what slot 1 showed, as in game)
local right, total = 0, 0
for i = 1, #presses - 1 do
  local p = presses[i]
  local shown
  for _, q in ipairs(picks) do
    if q.t <= p.t then
      shown = q
    else
      break
    end
  end
  local base = function(id)
    return id and (M.baseOf[id] or id)
  end
  if shown and base(shown.s1) == base(p.id) then
    total = total + 1
    if shown.s2 and base(shown.s2) == base(presses[i + 1].id) then
      right = right + 1
    end
  end
end
print(string.format("REAL %.1f %d", total > 0 and 100 * right / total or 0, total))
