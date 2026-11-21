-- tools/count-error.lua: how far the addon's resource counts are from the truth (owner, 2026-11-21).
--
-- Replays top players' fights from data/resource-truth/<spec>.json (tools/wcl-truth.py: every cast with the true
-- amount of each resource right before it) through the addon itself: the game's "usable / not enough" answers are
-- given from the truth at each cast, as in game, then the cast happens and the addon counts it. Before each cast it
-- compares what the addon believes with what was really there.
--
-- Per spec and resource: casts compared, mean error (ours - truth), the 10th / 90th percentile, and how often we
-- counted at least 10% of the maximum more than there was ("over") or less ("under"). Over is what starves a spell:
-- slot 1 offers it, the press is refused. Under holds a spell back that could have gone.
--
-- Usage: lua5.1 tools/count-error.lua [spec ...]          (all specs with truth data when none named)
--        COUNT_JSON=1 lua5.1 tools/count-error.lua ...     (one JSON line per spec and resource, for tools)
package.path = "./tests/?.lua;" .. package.path
local mock = require("wow_mock")
local print = print -- (the mock captures the game's print)
mock.Install(_G)

local function ReadJSON(path)
  local f = io.open(path)
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  -- tiny JSON reader: arrays, objects, numbers, strings (all wcl-truth.py writes)
  local pos = 1
  local function ws()
    pos = text:find("[^%s]", pos) or #text + 1
  end
  local value
  local function str()
    local s, e = text:find('^"[^"]*"', pos)
    pos = e + 1
    return text:sub(s + 1, e - 1)
  end
  function value()
    ws()
    local c = text:sub(pos, pos)
    if c == "{" then
      pos = pos + 1
      local o = {}
      ws()
      if text:sub(pos, pos) == "}" then
        pos = pos + 1
        return o
      end
      while true do
        ws()
        local k = str()
        ws()
        pos = pos + 1 -- :
        o[k] = value()
        ws()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "}" then
          return o
        end
      end
    elseif c == "[" then
      pos = pos + 1
      local a = {}
      ws()
      if text:sub(pos, pos) == "]" then
        pos = pos + 1
        return a
      end
      while true do
        a[#a + 1] = value()
        ws()
        local d = text:sub(pos, pos)
        pos = pos + 1
        if d == "]" then
          return a
        end
      end
    elseif c == '"' then
      return str()
    else
      local s, e = text:find("^-?[%d%.eE+-]+", pos)
      pos = e + 1
      return tonumber(text:sub(s, e))
    end
  end
  return value()
end

-- Warcraft Logs stores these ten times finer than the game's UI (Astral Power 1000 = 100)
local TENTHS = { [1] = 10, [6] = 10, [7] = 10, [8] = 10, [13] = 100 } -- (Insanity: hundredths)
local COUNTED = { [0] = true, [1] = true, [2] = true, [3] = true, [5] = true, [6] = true, [8] = true, [11] = true,
  [13] = true, [17] = true, [19] = true }

local function Boot()
  mock.frames, mock.timers, mock.printed = {}, {}, {}
  mock.now = 1000
  mock.restricted, mock.inCombat, mock.hasTarget = false, false, true
  mock.gameType = "standard"
  WOW_PROJECT_ID = 1 -- luacheck: ignore 111
  DMGAssistDB = nil -- luacheck: ignore 111
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 103 }, 1
  local ns = mock.LoadAddon("addons/DMGAssist", "DMGAssist")
  mock.Fire("ADDON_LOADED", "DMGAssist")
  mock.Fire("PLAYER_LOGIN")
  return ns
end

local function Pct(list, p)
  if #list == 0 then
    return 0
  end
  table.sort(list)
  return list[math.max(1, math.min(#list, math.floor(p * #list + 0.5)))]
end

local ns = Boot()
local specs = { ... }
if #specs == 0 then
  local p = io.popen("ls data/resource-truth/*.json 2>/dev/null")
  for line in p:lines() do
    specs[#specs + 1] = line:match("([%w_]+)%.json$")
  end
  p:close()
end

local all = {}
for _, key in ipairs(specs) do
  local fights = ReadJSON("data/resource-truth/" .. key .. ".json") or {}
  local record = ns.Data.specs.midnight[key]
  if record and #fights > 0 then
    if type(record) == "function" then
      record = record()
    end
    local stats = {}
    for _, fight in ipairs(fights) do
      ns = Boot()
      local M, S, C = ns.SpellMap, ns.State, ns.Clues
      local book = {}
      for id, info in pairs(record.spellInfo or {}) do
        if not info.pas then
          book[#book + 1] = { spellID = id, name = info.n }
        end
      end
      mock.book = book
      mock.power, mock.powerMax, mock.powerReadable = {}, {}, {}
      for spt, m in pairs(fight.max or {}) do
        local pt = tonumber(spt)
        mock.powerMax[pt] = TENTHS[pt] and m / TENTHS[pt] or m
      end
      for id, k in pairs(ns.Specs.KEYS) do
        if k == key then
          local cls = key:match("^(%a+)_"):upper()
          mock.class, mock.specs, mock.specIndex = { cls, cls, 0 }, { [1] = id }, 1
        end
      end
      ns.Specs.current = { key = key, status = "ready", data = record, branch = "midnight", client = "Midnight" }
      -- (INCOME_SCALE: try another passive income, for tools/calibrate-income.py)
      local scale = tonumber(os.getenv("INCOME_SCALE") or "")
      local it = ns.Data.incomeTruth and ns.Data.incomeTruth[key]
      if scale and it then
        local scaled = {}
        for pt, v in pairs(it) do
          scaled[pt] = v * scale
        end
        ns.Data.incomeTruth[key] = scaled
      end
      M.SetData(record)
      M.Refresh()
      S.Bind(key)
      -- the costs the game states (the addon reads them live): the most common real cost of each spell
      local seen = {}
      for _, c in ipairs(fight.casts or {}) do
        for spt, v in pairs(c[4] or {}) do
          local pt = tonumber(spt)
          seen[c[2]] = seen[c[2]] or {}
          seen[c[2]][pt] = seen[c[2]][pt] or {}
          table.insert(seen[c[2]][pt], TENTHS[pt] and v / TENTHS[pt] or v)
        end
      end
      mock.powerCost = {}
      for id, byPt in pairs(seen) do
        local info = M.Info(id)
        local list = {}
        for pt, l in pairs(byPt) do
          table.sort(l)
          list[#list + 1] = { type = pt, cost = l[math.floor(#l / 2) + 1] }
        end
        mock.powerCost[id] = list -- (GetSpellPowerCost: the game's live answer)
        if info then
          local live = {}
          for pt, list in pairs(byPt) do
            table.sort(list)
            live[pt] = list[math.floor(#list / 2) + 1]
          end
          info.costLive = live
        end
      end
      -- the game's stated regeneration (GetPowerRegen) for the regenerating primary resource: base rate with a
      -- raid gear haste of HASTE (default 25%)
      local haste = 1 + (tonumber(os.getenv("HASTE")) or 25) / 100
      mock.powerType, mock.powerRegen = nil, nil
      for spt in pairs(fight.max or {}) do
        local pt = tonumber(spt)
        if pt == 3 or pt == 2 then
          mock.powerType, mock.powerRegen = pt, (pt == 3 and 10 or 5) * haste
        end
      end
      mock.inCombat, mock.restricted = true, true
      mock.Fire("PLAYER_REGEN_DISABLED")
      local t0 = mock.now
      for _, c in ipairs(fight.casts or {}) do
        local t, id, have = c[1], c[2], c[3]
        mock.now = t0 + t
        local truth = {}
        for spt, v in pairs(have or {}) do
          local pt = tonumber(spt)
          truth[pt] = TENTHS[pt] and v / TENTHS[pt] or v
        end
        -- the costs the game states right now: this cast's real cost (none when a proc made it free), the others'
        -- usual; the addon reads them every pass (State.ReadLiveCosts)
        local thisCost = {}
        for spt, v in pairs(c[4] or {}) do
          local pt = tonumber(spt)
          thisCost[#thisCost + 1] = { type = pt, cost = TENTHS[pt] and v / TENTHS[pt] or v }
        end
        local usual = mock.powerCost[id]
        mock.powerCost[id] = thisCost
        S.ReadLiveCosts()
        if os.getenv("LIVEDBG") and id == tonumber(os.getenv("LIVEDBG")) then
          local li = M.live[M.Info(id) or false]
          io.stderr:write(string.format("LIVE t=%.1f book=%s live=%s n=%d\n", t, tostring(M.book and M.book[id] ~= nil),
            li and (next(li) and tostring(select(2, next(li))) or "free") or "none", #thisCost))
        end
        -- the game's answers right now, from the truth
        mock.usable = {}
        for _, b in ipairs(book) do
          local cost = M.Cost(M.Info(b.spellID))
          if cost then
            local ok, short = true, false
            for pt, amount in pairs(cost) do
              if truth[pt] and amount > 0 and truth[pt] < amount then
                ok, short = false, true
              end
            end
            mock.usable[b.spellID] = { ok, short }
          end
        end
        for pt, v in pairs(truth) do
          if COUNTED[pt] then
            local lo = C.ResourceBounds(pt)
            if os.getenv("FLOOR") then
              lo = C.FloorBounds(pt)
            end
            if type(lo) == "number" then
              local max = mock.powerMax[pt] or 100
              local s = stats[pt] or { errs = {}, over = 0, under = 0, n = 0 }
              stats[pt] = s
              local e = lo - v
              if os.getenv("TRACE") and pt == tonumber(os.getenv("TRACE")) and s.n < 40 then
                io.stderr:write(string.format("T %6.1f id=%-7d truth %6.1f ours %6.1f floor %s\n", t, id, v, lo,
                  tostring(C.FloorBounds(pt))))
              end
              s.errs[#s.errs + 1] = e
              s.n = s.n + 1
              if e > 0.1 * max then
                s.over = s.over + 1
              elseif e < -0.1 * max then
                s.under = s.under + 1
              end
              s.max = max
            end
          end
        end
        mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-" .. t, id)
        mock.powerCost[id] = usual
      end
      mock.inCombat = false
      mock.Fire("PLAYER_REGEN_ENABLED")
    end
    for pt, s in pairs(stats) do
      local sum = 0
      for _, e in ipairs(s.errs) do
        sum = sum + e
      end
      local row = { spec = key, pt = pt, n = s.n, mean = sum / s.n, p10 = Pct(s.errs, 0.1), p90 = Pct(s.errs, 0.9),
        over = 100 * s.over / s.n, under = 100 * s.under / s.n, max = s.max }
      all[#all + 1] = row
    end
  end
end
table.sort(all, function(a, b)
  return a.spec < b.spec or (a.spec == b.spec and a.pt < b.pt)
end)
for _, r in ipairs(all) do
  if os.getenv("COUNT_JSON") then
    print(string.format('{"spec":"%s","pt":%d,"n":%d,"mean":%.2f,"p10":%.2f,"p90":%.2f,"over":%.1f,"under":%.1f,'
      .. '"max":%s}', r.spec, r.pt, r.n, r.mean, r.p10, r.p90, r.over, r.under, tostring(r.max)))
  else
    print(string.format("%-26s pt%-2d n=%-4d mean %+8.1f  p10 %+8.1f  p90 %+8.1f  over %5.1f%%  under %5.1f%%  (max %s)",
      r.spec, r.pt, r.n, r.mean, r.p10, r.p90, r.over, r.under, tostring(r.max)))
  end
end
