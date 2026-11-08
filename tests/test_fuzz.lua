-- Run from the repo root:  lua5.1 tests/test_fuzz.lua [scenarios-per-spec]
-- Every spec's real SimC data, on both clients, through random game states (readable and secret): the engine,
-- look-ahead, branches, interrupts, defensives and the HUD must never error, must clean up the look-ahead overlay,
-- and should nearly always produce a pick. Prints a per-spec table and fails on any error.
package.path = "./tests/?.lua;" .. package.path

local mock = require("wow_mock")
local print = print
mock.Install(_G)

local N = tonumber(arg and arg[1]) or 25
math.randomseed(20261108)

local function Boot(gameType, project)
  mock.frames, mock.timers, mock.printed = {}, {}, {}
  mock.restricted, mock.inCombat, mock.hasTarget = false, false, true
  mock.gameType = gameType
  WOW_PROJECT_ID = project
  DMGAssistDB = nil
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 103 }, 1
  local ns = mock.LoadAddon("addons/DMGAssist", "DMGAssist")
  mock.Fire("ADDON_LOADED", "DMGAssist")
  mock.Fire("PLAYER_LOGIN")
  return ns
end

local DISCRETE = { [4] = true, [7] = true, [9] = true, [12] = true, [16] = true, [19] = true }

-- A spellbook with one castable spell per action token the record's data knows.
local function BookFor(record)
  local book, seen = {}, {}
  for token, e in pairs(record.spells or {}) do
    local id = e.a and e.a[1]
    local info = id and record.spellInfo[id]
    if id and not seen[id] and info and not info.pas then
      seen[id] = true
      book[#book + 1] = { spellID = id, name = token }
    end
  end
  table.sort(book, function(a, b) return a.spellID < b.spellID end)
  return book
end

local function PowerTypes(record)
  local used = {}
  for _, info in pairs(record.spellInfo or {}) do
    for _, t in ipairs({ info.cost or {}, info.gain or {} }) do
      for pt in pairs(t) do
        used[pt] = true
      end
    end
  end
  return used
end

local function Randomize(ns, record, book)
  mock.restricted = math.random() < 0.6
  mock.inCombat = mock.restricted or math.random() < 0.3
  mock.power, mock.powerMax, mock.powerReadable = {}, {}, {}
  for pt in pairs(PowerTypes(record)) do
    local max = DISCRETE[pt] and 5 or 100
    mock.powerMax[pt] = max
    mock.power[pt] = math.random(0, max)
    mock.powerReadable[pt] = DISCRETE[pt] and math.random() < 0.5
  end
  mock.cooldowns, mock.usable = {}, {}
  for _, b in ipairs(book) do
    local r = math.random()
    if r < 0.25 then
      mock.cooldowns[b.spellID] = { active = true, start = mock.now - 1, duration = 10 }
    elseif r < 0.35 then
      mock.usable[b.spellID] = { false, math.random() < 0.7 }
    end
  end
  mock.acSpell = (#book > 0 and math.random() < 0.5) and book[math.random(#book)].spellID or nil
  mock.casting = (#book > 0 and math.random() < 0.15) and { id = book[math.random(#book)].spellID, endsIn = 1 } or nil
  mock.targetCast = math.random() < 0.2 and { notInterruptible = math.random() < 0.3, id = 77 } or nil
  mock.nameplates = math.random(0, 6)
  mock.inRange = math.random() < 0.5 and {} or nil
  ns.db.mode = math.random() < 0.5 and "st" or "aoe"
  ns.db.autoDetect = math.random() < 0.5
  mock.auras.player = {}
  mock.auras.target = {}
  mock.Fire("UNIT_AURA", "player")
  mock.Fire("UNIT_AURA", "target")
  mock.Advance(0.05 + math.random())
end

local totalErrors, totalNil, totalRuns, slowest = 0, 0, 0, 0
local report = {}

for _, client in ipairs({ { "standard", 1, "midnight" }, { "camelot", 18, "forever" } }) do
  local ns = Boot(client[1], client[2])
  local keys = {}
  for key in pairs(ns.Data.specs[client[3]]) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local record = ns.Data.specs[client[3]][key]
    local book = BookFor(record)
    mock.book = book
    ns.SpellMap.SetData(record)
    ns.SpellMap.Refresh()
    ns.State.Bind(key)
    local errors, nils, firstErr = 0, 0, nil
    local t0 = os.clock()
    for _ = 1, N do
      Randomize(ns, record, book)
      local ok, r = pcall(ns.Engine.Recommend, record, { useAssisted = client[3] == "midnight", burst = true })
      if ok then
        if ns.State.Lookahead() ~= nil then
          ok, r = false, "look-ahead overlay left active"
        elseif not r.main then
          nils = nils + 1
        else
          for i, p in ipairs(r.queue or {}) do
            if type(p.id) ~= "number" then
              ok, r = false, "queue slot " .. i .. " has no spell id"
            end
          end
        end
      end
      if ok then
        ok, r = pcall(function()
          ns.Interrupts.Apply(r)
          ns.Defensives.Apply(r)
          r.callout = ns.BossMods.Callout()
          ns.Display.Update(r, true)
          return r
        end)
      end
      if not ok then
        errors = errors + 1
        firstErr = firstErr or tostring(r)
        ns.State.EndLookahead()
      end
    end
    local ms = (os.clock() - t0) / N * 1000
    slowest = math.max(slowest, ms)
    totalErrors, totalNil, totalRuns = totalErrors + errors, totalNil + nils, totalRuns + N
    report[#report + 1] = string.format("%-9s %-26s book %3d  errors %2d  no-pick %2d/%d  %.2f ms%s", client[3], key,
      #book, errors, nils, N, ms, firstErr and ("\n          first error: " .. firstErr) or "")
  end
end

print("DMGAssist fuzz: every spec, both clients, random states")
for _, line in ipairs(report) do
  print("  " .. line)
end
print(string.format("\n%d runs, %d errors, %d without a pick (%.1f%%), slowest spec %.2f ms per decision+render",
  totalRuns, totalErrors, totalNil, 100 * totalNil / totalRuns, slowest))
if totalErrors > 0 then
  os.exit(1)
end
