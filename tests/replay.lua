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
-- --cost: what a pass costs on this machine (os.clock), with Flow mode on
-- (owner, 2026-11-16: 59 FPS without DMGAssist, 36 with it in Flow mode)
local costMode = arg[2] == "--cost"
local cost = { update = 0, frames = 0, n = 0 }
-- --profile: where a pass spends its time (sampled every 1000 VM instructions, by function)
local profile = arg[2] == "--profile"
local samples = {}
if profile then
  costMode = true
  debug.sethook(function()
    local info = debug.getinfo(2, "Sn")
    if info then
      local k = (info.short_src or "?"):gsub("^.*/", "") .. ":" .. tostring(info.linedefined) .. " " .. tostring(info.name)
      samples[k] = (samples[k] or 0) + 1
    end
  end, "", 1000)
end

mock.frames, mock.timers, mock.printed = {}, {}, {}
mock.restricted, mock.inCombat, mock.hasTarget = false, false, true
mock.gameType = "standard"
WOW_PROJECT_ID = 1
DMGAssistDB = nil
local ns = mock.LoadAddon("addons/DMGAssist", "DMGAssist")
if os.getenv("SCEN_SIGNALS") then
  ns.Signals.MISS_LOGS = math.max(30, tonumber(os.getenv("SCEN_SIGNALS")) or 0)
end
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

-- what the addon knew at the pull (Record.lua "L" lines): its clocks, its memory, what it learned over past fights.
-- The clock starts at the recorded pull time, so the snapshot's GetTime() values line up.
mock.now = input.start or mock.now
-- (the learner's and the calibration's memory are filed under spec + talent loadout: they are put in place once the
-- recorded answers can tell the loadout, at the first recorded pass - before that they went into an "unknown
-- loadout" store and the replayed learner never went live, 2026-11-16)
local function ApplySnapshot(only)
  for name, lit in pairs(input.snapshot or {}) do
    local late = name == "calibrate" or name == "learner"
    if late == only then
      local fn = loadstring("return " .. lit)
      local ok, v = pcall(fn or function() end)
      if ok and type(v) == "table" then
        local into = ({ state = S, learned = S.learned, clues = ns.Clues })[name]
        if name == "calibrate" then
          into = ns.Calibrate.Store()
        elseif name == "learner" then
          into = ns.Learner.Store()
        end
        for k, item in pairs(into and v or {}) do
          into[k] = item
        end
      end
    end
  end
end
ApplySnapshot(false)
local lateSnapshot = true

-- answers
local shapes = {} -- Record.lua "Q <id> field,field,...": a table answer's shape
local function Dec(s)
  if s:sub(1, 1) == "#" then
    local id, body = s:match("^#(%d+):(.*)$")
    local fields = id and shapes[tonumber(id)]
    if not fields then
      return nil
    end
    local t, i = {}, 0
    for item in (body .. "/"):gmatch("([^/]*)/") do
      i = i + 1
      local k = fields[i]
      if k then
        t[tonumber(k) or k] = Dec(item)
      end
    end
    return t
  end
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
local callCount, callWhere, whereFor
callCount = 0 -- (game calls answered from the recording)
callWhere = nil -- (--cost: which code asked, per event)
R.replay = function(fn, ...)
  callCount = callCount + 1
  if callWhere then
    local qkey = R.Key(fn, { n = select("#", ...), ... }) or "?"
    local k = tostring(qkey):gsub("%(.*", "")
    local tb = debug.traceback("", 2)
    for line in tb:gmatch("[^\n]+") do
      local src, ln = line:match("([%w_]+%.lua):(%d+):")
      if src and src ~= "Util.lua" and src ~= "Signals.lua" and src ~= "Record.lua" and src ~= "replay.lua"
          and src ~= "wow_mock.lua" then
        k = k .. " <- " .. src .. ":" .. ln
        break
      end
    end
    callWhere[k] = (callWhere[k] or 0) + 1
  end
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
local picks, presses, castStarts = {}, {}, {}
local sinceT = {} -- events fired since the last recorded pass
local inv = { passes = 0, uncastable = 0, movement = 0 } -- invariant breaks (INV line)
local evCost, evN, evCalls = {}, {}, {} -- time and game calls in each event's handlers (--cost)
mock.inCombat, mock.restricted = true, true
for _, line in ipairs(input.lines) do
  local kind = line:sub(1, 1)
  if kind == "Q" then
    local id, sig = line:match("^Q (%d+) (.*)$")
    local fields = {}
    for f in sig:gmatch("[^,]+") do
      fields[#fields + 1] = f
    end
    shapes[tonumber(id)] = fields
  elseif kind == "K" then
    local id, q = line:match("^K (%d+) (.*)$")
    keys[tonumber(id)] = q
  elseif kind == "T" then
    local t, updates = line:match("^T ([%d.]+)|(.*)$")
    mock.now = t0 + tonumber(t)
    Apply(updates)
    -- The recording keeps the game's answers per pass, so what the addon asked while handling an event got the
    -- answers of the pass before; the event's change lands here. Signal the events again with their answers.
    for ev in pairs(sinceT) do
      ns.Signals.OnEvent(ev)
    end
    sinceT = {}
    if lateSnapshot then
      lateSnapshot = false
      ApplySnapshot(true)
      ns.Signals.All("replay start") -- (what the pieces kept from before the recorded answers isn't the game's)
      ns.Signals.Reset()
      if os.getenv("SCEN_SIGMODE") then -- shadow / live / off (cost comparisons)
        ns.db.signalsMode = os.getenv("SCEN_SIGMODE")
      end
    end
    local c0 = os.clock()
    local ok, r = pcall(ns.Update)
    cost.update, cost.n = cost.update + os.clock() - c0, cost.n + 1
    if costMode then -- the per-frame work that runs between passes (Flow mode's lanes, the HUD's timing)
      c0 = os.clock()
      for _ = 1, 6 do -- (a pass every 0.1 s, ~6 frames between passes at 60 fps)
        pcall(ns.Game.Render)
        local hud = ns.Display and ns.Display.frame
        local onUpdate = hud and hud.GetScript and hud:GetScript("OnUpdate")
        if onUpdate then
          pcall(onUpdate, hud, 1 / 60)
        end
      end
      cost.frames = cost.frames + os.clock() - c0
    end
    if ok and r and r.main then
      local q2 = r.queue and r.queue[2]
      -- (names taken now: after the fight the spell map can be gone, and every comparison read "different" -
      -- Subtlety "matched" 6% of what was shown, 2026-11-18)
      picks[#picks + 1] = { t = tonumber(t), s1 = r.main.id, s2 = q2 and q2.id or nil,
        t1 = r.main.token or M.TokenForID(r.main.id), t2 = q2 and (q2.token or M.TokenForID(q2.id)) or nil }
      if showPicks then
        print(string.format("PICK %.2f %s %s", tonumber(t), tostring(r.main.id), tostring(q2 and q2.id)))
      end
      -- (TERM=name[,name]: those rotation terms at every decision, with slot 1 and 2 - to see what a line read)
      if os.getenv("TERM_DBG") then
        local vals = {}
        for name in os.getenv("TERM_DBG"):gmatch("[^,]+") do
          vals[#vals + 1] = name .. "=" .. tostring(ns.State.Resolve(name, {}))
        end
        io.stderr:write(string.format("TERM %.2f %s %s %s\n", tonumber(t), tostring(r.main.token),
          tostring(q2 and q2.token), table.concat(vals, " ")))
      end
      if os.getenv("CASTDBG") then
        local cid, left = ns.State.CurrentCast()
        io.stderr:write(string.format("CAST %.2f main=%s cast=%s left=%s src=%s ready=%.2f gcd=%.2f\n", tonumber(t),
          tostring(r.main.token), tostring(cid), tostring(left and string.format("%.2f", left)),
          tostring(ns.State.castSource), ns.Engine.ReadyIn(), ns.State.GCDRemains() or -1))
      end
      local at = tonumber(os.getenv("TRACE_AT") or "")
      if at and math.abs(tonumber(t) - at) < 0.06 then
        local tr = ns.Engine.Recommend(ns.ActiveRecord(ns.Specs.current), { burst = true, trace = true,
          useAssisted = true })
        io.stderr:write(string.format("TRACE %.2f main=%s(%s) steadied=%s\n", tonumber(t), tostring(r.main.token),
          tostring(r.main.source), tostring(r.steadied)))
        for _, l in ipairs(tr.trace or {}) do
          io.stderr:write("  " .. l .. "\n")
        end
      end
      -- Invariants (owner, 2026-11-18: "we make changes to fix 1 thing, and then literally break half the specs"):
      -- slot 1 never a spell the game called neither usable nor short of a resource (unless waiting by design), never
      -- a spell that moves you, never one you don't have (not in the book, on no button now).
      local uk = R.Key(C_Spell.IsSpellUsable, { n = 1, r.main.id })
      local u = uk and answer[uk]
      if u and u[1] == false and u[2] == false and r.main.source ~= "pool" then
        inv.uncastable = inv.uncastable + 1
        if os.getenv("UNCDBG") then
          io.stderr:write("UNC " .. tostring(r.main.token) .. " " .. tostring(r.main.source) .. "\n")
        end
      end
      if r.main.token and ns.Engine.MOVEMENT and ns.Engine.MOVEMENT[r.main.token] then
        inv.movement = inv.movement + 1
      end
      inv.passes = inv.passes + 1
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
      if ev == "UNIT_SPELLCAST_START" and a[1] == "player" then
        castStarts[a[3] or 0] = tonumber(t) -- (a cast-time spell is decided when its cast begins)
      end
      if ev == "UNIT_SPELLCAST_SUCCEEDED" and a[1] == "player" then
        local st = castStarts[a[3] or 0]
        local decided = st and tonumber(t) - st < 10 and st or tonumber(t)
        castStarts[a[3] or 0] = nil
        presses[#presses + 1] = { t = tonumber(t), id = a[3], decided = decided }
        if os.getenv("PRESSDBG") then
          io.stderr:write(string.format("PRESS t=%.2f decided=%.2f %s\n", tonumber(t), decided, tostring(a[3])))
        end
      end
      sinceT[ev] = true
      local e0 = os.clock()
      local calls0 = callCount
      if costMode and os.getenv("SCEN_WHERE") == ev then
        callWhere = whereFor or {}
        whereFor = callWhere
      end
      pcall(mock.Fire, ev, a[1], a[2], a[3], a[4], a[5], a[6])
      callWhere = nil
      evCalls[ev] = (evCalls[ev] or 0) + callCount - calls0
      evCost[ev] = (evCost[ev] or 0) + os.clock() - e0
      evN[ev] = (evN[ev] or 0) + 1
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
    local t1 = best.t1 or M.TokenForID(best.s1)
    local t2 = best.t2 or (best.s2 and M.TokenForID(best.s2))
    if t1 == g.main then
      same1 = same1 + 1
    elseif os.getenv("SAMEDBG") then
      io.stderr:write(string.format("DIFF t=%.2f shown=%s replay=%s(%s)\n", g.t, tostring(g.main), tostring(t1),
        tostring(best.s1)))
    end
    if t2 == g.next then
      same2 = same2 + 1
    elseif os.getenv("SAMEDBG") then
      io.stderr:write(string.format("DIFF2 t=%.2f shown2=%s replay2=%s\n", g.t, tostring(g.next), tostring(t2)))
    end
  end
end
if profile then
  debug.sethook()
  local list, total = {}, 0
  for k, v in pairs(samples) do
    list[#list + 1] = { k, v }
    total = total + v
  end
  table.sort(list, function(a, b)
    return a[2] > b[2]
  end)
  for i = 1, math.min(40, #list) do
    print(string.format("PROF %5.1f%% %s", 100 * list[i][2] / total, list[i][1]))
  end
end
if costMode then
  print(string.format("COST %.3f ms per pass, %.3f ms per frame of drawing (%d passes)", 1000 * cost.update / math.max(cost.n, 1),
    1000 * cost.frames / math.max(cost.n * 6, 1), cost.n))
end
if costMode then
  local list = {}
  for ev, c in pairs(evCost) do
    list[#list + 1] = { ev = ev, c = c }
  end
  table.sort(list, function(x, y)
    return x.c > y.c
  end)
  for i = 1, math.min(6, #list) do
    print(string.format("EVCOST %s %.3f ms each (%d), %.0f game calls each", list[i].ev,
      1000 * list[i].c / evN[list[i].ev], evN[list[i].ev], (evCalls[list[i].ev] or 0) / evN[list[i].ev]))
  end
end
if os.getenv("SCEN_DBG") then
  local l = {}
  for id, v in pairs(ns.State.learned.cd or {}) do l[#l + 1] = id .. "=" .. string.format("%.1f", v) end
  table.sort(l)
  print("DBG inferred=" .. tostring(ns.State.castsInferred) .. " learned=" .. table.concat(l, ","))
end
if whereFor then
  local list = {}
  for k, c in pairs(whereFor) do
    list[#list + 1] = { k = k, c = c }
  end
  table.sort(list, function(x, y)
    return x.c > y.c
  end)
  for i = 1, math.min(12, #list) do
    print(string.format("WHERE %s %d", list[i].k, list[i].c))
  end
end
if os.getenv("SCEN_SIGNALS") then -- (MISS_LOGS raised at the top)
  print("SIGNALS " .. ns.Signals.Summary())
  local by = {}
  for k, c in pairs(ns.Signals.missBy) do
    by[#by + 1] = { k = k, c = c }
  end
  table.sort(by, function(a, b)
    return a.c > b.c
  end)
  for i = 1, math.min(25, #by) do
    print("  MISSBY " .. by[i].c .. " " .. by[i].k)
  end
  for i, m in ipairs(ns.Signals.misses) do
    if i <= tonumber(os.getenv("SCEN_SIGNALS")) then
      print(string.format("  MISS %s %s held=%s game=%s age=%s last=%s (%s s ago)", m.piece, m.q, m.held, m.game,
        m.age, m.last, m.lastAgo))
    end
  end
end
-- slot 1 changes per minute that no press explains (a press: a cast start or success within 0.35 s before)
local changes, lastS1 = 0, nil
local pressT = {}
for _, p in ipairs(presses) do
  pressT[#pressT + 1] = p.decided or p.t
  pressT[#pressT + 1] = p.t
end
for _, p in ipairs(picks) do
  if lastS1 and p.s1 ~= lastS1 then
    local explained = false
    for _, pt in ipairs(pressT) do
      if p.t - pt >= -0.05 and p.t - pt < 0.35 then
        explained = true
        break
      end
    end
    if not explained then
      changes = changes + 1
    end
  end
  lastS1 = p.s1
end
local span = (#picks > 1 and picks[#picks].t - picks[1].t or 0) / 60
print(string.format("INV uncastable=%d movement=%d passes=%d unexplained_per_min=%.1f", inv.uncastable,
  inv.movement, inv.passes, span > 0 and changes / span or 0))
print(string.format("SAME %.1f %.1f %d", n > 0 and 100 * same1 / n or 0, n > 0 and 100 * same2 / n or 0, n))

-- slot 2 vs the press that came next (only after a press of what slot 1 showed, as in game)
local right, total = 0, 0
for i = 1, #presses - 1 do
  local p = presses[i]
  local shown
  for _, q in ipairs(picks) do
    if q.t <= p.decided then
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
