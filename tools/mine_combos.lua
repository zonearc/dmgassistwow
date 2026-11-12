-- Combo miner (run from the repo root):  lua5.1 tools/mine_combos.lua > addons/DMGAssist/Data/Combos.lua
--
-- A combo is a short chain each spec reliably casts right after a major cooldown (decided 2026-11-12: "whenever
-- you hit this CD you universally always hit this spell and then that spell after"). Found here, not by hand:
-- every spec plays long simulated dummy fights through the real pipeline (tests/test_scenarios.lua), and for
-- each major cooldown pressed, the next casts are compared. The longest chain (2-4 spells, the cooldown first)
-- (a major cooldown or any spell with a 30 s+ cooldown)
-- that follows at least MIN_SHARE of its presses, seen at least MIN_SEEN times, becomes a combo. A chain of the
-- cooldown and only the spec's filler isn't one (nothing to learn).
--
-- Filters (the simulation is simple: no procs, few resources): trailing repeats of one spell are trimmed (a
-- cooldown then three Fireballs is "cooldown > Fireball"); the chain needs a spell after the cooldown that isn't
-- the spec's filler; spells that can't be cast in combat (Stealth) never count; a chain that starts inside a
-- longer one of the same spec is left out; seen at least MIN_SEEN times.
--   lua5.1 tools/mine_combos.lua --save /tmp/fights.lua   (also keeps the simulated casts)
--   lua5.1 tools/mine_combos.lua --from /tmp/fights.lua   (re-reads them: no simulation)
package.path = "./tests/?.lua;" .. package.path
local MIN_SHARE, MIN_SEEN, FIGHT = 0.6, 3, 300
local NOT_IN_COMBAT = { stealth = true, shadowmeld = true, prowl = true, camouflage = true }
local SAVE, FROM
do
  local a = arg or {}
  for i = 1, #a do
    if a[i] == "--save" then
      SAVE = a[i + 1]
    elseif a[i] == "--from" then
      FROM = a[i + 1]
    end
  end
end

_G.SCEN_FIGHT, _G.SCEN_NOEXIT = FIGHT, true
local presses, out = {}, {}
_G.SCEN_PRESS = function(_, id)
  presses[#presses + 1] = id
end

local realPrint = print
local fights = {}
_G.SCEN_RESULTS = function(fid)
  fights[#fights + 1] = { id = fid, presses = presses }
  presses = {}
end
if FROM then
  fights = dofile(FROM)
  _G.SCEN_FIGHT = nil
  local mock = require("wow_mock")
  mock.Install(_G)
  mock.frames, mock.timers, mock.printed = {}, {}, {}
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 103 }, 1
  _G.SCEN_NS = mock.LoadAddon("addons/DMGAssist", "DMGAssist")
else
  print = function() end -- the scenario table is noise here
  arg = {}
  dofile("tests/test_scenarios.lua")
  print = realPrint
  if SAVE then
    local f = assert(io.open(SAVE, "w"))
    f:write("return {\n")
    for _, fi in ipairs(fights) do
      f:write(string.format("{ id = %q, presses = { %s } },\n", fi.id, table.concat(fi.presses, ", ")))
    end
    f:write("}\n")
    f:close()
  end
end

local ns = _G.SCEN_NS
local M = ns.SpellMap
local bySpec = {}
for _, f in ipairs(fights) do
  local key, sc = f.id:match("^(.-)/(%w+)$")
  if sc == "st" or sc == "aoe" or sc == "group" then
    bySpec[key] = bySpec[key] or {}
    table.insert(bySpec[key], f.presses)
  end
end

local keys = {}
for k in pairs(bySpec) do
  keys[#keys + 1] = k
end
table.sort(keys)
out[#out + 1] = "-- Written by tools/mine_combos.lua from long simulated fights: each spec's chains after a major"
out[#out + 1] = "-- cooldown (spell IDs, the cooldown first). Combos.lua announces one when you finish it in Flow."
out[#out + 1] = "local _, ns = ..."
out[#out + 1] = "ns.COMBO_DATA = {"
for _, key in ipairs(keys) do
  local record = ns.Data.specs.midnight[key]
  M.SetData(record)
  local tokenOf = {}
  for token, e in pairs(record.spells or {}) do
    for _, sid in ipairs(e.a or {}) do
      tokenOf[sid] = tokenOf[sid] or token
    end
  end
  local function Token(id)
    return tokenOf[id] or M.TokenForID(id)
  end
  -- a chain starts at a cooldown: Blizzard's major cooldowns, or any spell with a cooldown of 30 s or more
  local majors = {}
  for _, t in ipairs(record.blizzardExcluded or {}) do
    majors[t] = true
  end
  local function Starter(id, token)
    if token and majors[token] then
      return true
    end
    local info = M.Info(id)
    return info ~= nil and (tonumber(info.cd) or 0) >= 30
  end
  -- the filler: the spell pressed most
  local count = {}
  for _, seq in ipairs(bySpec[key]) do
    for _, id in ipairs(seq) do
      count[id] = (count[id] or 0) + 1
    end
  end
  local filler, most = nil, 0
  for id, n in pairs(count) do
    if n > most then
      filler, most = id, n
    end
  end
  local chains = {}
  local starters = {}
  for _, seq in ipairs(bySpec[key]) do
    -- spells that can't be cast in combat are dropped from the sequence (the simulation presses Stealth)
    local clean = {}
    for _, id in ipairs(seq) do
      if not NOT_IN_COMBAT[Token(id) or ""] then
        clean[#clean + 1] = id
      end
    end
    for i, id in ipairs(clean) do
      local token = Token(id)
      if Starter(id, token) and clean[i + 1] then
        starters[id] = starters[id] or {}
        -- trailing repeats trimmed: cooldown > Fireball > Fireball > Fireball is cooldown > Fireball
        local o = { clean[i] }
        for k = i + 1, i + 3 do
          if clean[k] and clean[k] ~= o[#o] then
            o[#o + 1] = clean[k]
          elseif clean[k] then
            break
          end
        end
        table.insert(starters[id], o)
      end
    end
  end
  local starterIDs = {}
  for id in pairs(starters) do
    starterIDs[#starterIDs + 1] = id
  end
  table.sort(starterIDs)
  for _, sid in ipairs(starterIDs) do
    local occ = starters[sid]
    local best
    for len = 4, 2, -1 do
      local tally = {}
      for _, o in ipairs(occ) do
        if #o >= len then
          local k = table.concat(o, ",", 1, len)
          tally[k] = (tally[k] or 0) + 1
        end
      end
      for k, n in pairs(tally) do
        if n >= MIN_SEEN and n / #occ >= MIN_SHARE then
          local ids, interesting = {}, false
          for v in k:gmatch("%d+") do
            ids[#ids + 1] = tonumber(v)
            if #ids > 1 and tonumber(v) ~= filler and tonumber(v) ~= sid then
              interesting = true
            end
          end
          if interesting and #ids >= 2 and (not best or n > best.n) then
            best = { ids = ids, n = n, of = #occ }
          end
        end
      end
      if best then
        break
      end
    end
    if best then
      chains[#chains + 1] = best
    end
  end
  -- a chain whose cooldown sits inside a longer chain of this spec is part of that one
  local kept = {}
  for _, c in ipairs(chains) do
    local inside = false
    for _, o in ipairs(chains) do
      if o ~= c then
        for k = 2, #o.ids do
          if o.ids[k] == c.ids[1] then
            inside = true
          end
        end
      end
    end
    if not inside then
      kept[#kept + 1] = c
    end
  end
  if #kept > 0 then
    out[#out + 1] = string.format("  %s = {", key)
    for _, c in ipairs(kept) do
      local names = {}
      for _, id in ipairs(c.ids) do
        names[#names + 1] = Token(id) or tostring(id)
      end
      out[#out + 1] = string.format("    { %s }, -- %s (%d of %d)", table.concat(c.ids, ", "),
        table.concat(names, " > "), c.n, c.of)
    end
    out[#out + 1] = "  },"
  end
end
out[#out + 1] = "}"
realPrint(table.concat(out, "\n"))
