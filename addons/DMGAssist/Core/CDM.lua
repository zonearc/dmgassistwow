-- CDM.lua: Blizzard's Cooldown Manager as a signal (owner, 2026-11-14: "can you see on addon load if it's enabled ...
-- automatically start tracking when it's enabled ... see what it's not tracking and let them know in settings ...
-- we only want them to track what's important").
--
-- The Cooldown Manager is the game's own buff and cooldown tracker. Its buff icons are driven by Blizzard's secure
-- code, which sees every aura, so a buff the player tracks there can tell us about procs the game hides from addons
-- in combat. Nothing to switch on in DMGAssist: when the Cooldown Manager is on, its tracked buffs are read
-- (Clues.ReadCooldownManager). Every reading is graded against the truth whenever auras are readable, like every
-- other clue, and switched off for this player if it turns out wrong.
--
-- What's worth tracking: the buffs your spec's rotation checks (SimC's and Blizzard's lists) that you don't cast
-- yourself - procs and talent effects (Hot Streak, Opportunity, Sudden Death). DMGAssist already follows the buffs
-- you cast from its own clock, and the spells' cooldowns from your bars, so those would only be clutter. Settings
-- (Integrations) list the key buffs: tracked, or "add it" when the Cooldown Manager offers it.
--
-- Only widget methods and plain fields are read (never Blizzard's Lua functions on these frames: taint).

local _, ns = ...
local U, M = ns.U, ns.SpellMap

local CDM = {}
ns.CDM = CDM

CDM.BUFF_VIEWERS = { "BuffIconCooldownViewer", "BuffBarCooldownViewer" }
CDM.ALL_VIEWERS = { "EssentialCooldownViewer", "UtilityCooldownViewer", "BuffIconCooldownViewer",
  "BuffBarCooldownViewer" }
CDM.KEY_MAX = 6 -- the most key buffs suggested (the rest add little and clutter the screen)
-- buffs other players or items give: not yours to track
CDM.EXTERNAL = { bloodlust = true, heroism = true, time_warp = true, primal_rage = true, fury_of_the_aspects = true,
  ancient_hysteria = true, power_infusion = true, potion = true, tempered_potion = true }

local infoCache = {} -- cooldownID -> { sid, tokens = { token = true }, name } (the catalog doesn't change)

-- On, off, or nil when this game has no Cooldown Manager.
function CDM.Enabled()
  if not C_CooldownViewer then
    return nil
  end
  local available = U.Get(C_CooldownViewer.IsCooldownViewerAvailable)
  if available == false then
    return false
  end
  local v = U.Get(C_CVar and C_CVar.GetCVar, "cooldownViewerEnabled")
  if v == nil then
    v = U.Get(GetCVar, "cooldownViewerEnabled")
  end
  if v ~= nil then
    return v == "1" or v == 1 or v == true
  end
  local viewer = _G.BuffIconCooldownViewer
  return type(viewer) == "table" and U.Get(viewer.IsShown, viewer) == true or nil
end

-- What a cooldown ID stands for: its spell, every token it could match (the spell, its override, linked auras).
function CDM.Info(cdID)
  if type(cdID) ~= "number" then
    return nil
  end
  local c = infoCache[cdID]
  if c then
    return c
  end
  local info = U.Get(C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCooldownInfo, cdID)
  if type(info) ~= "table" then
    return nil
  end
  c = { sid = U.Read(info.spellID), tokens = {} }
  local function add(id)
    id = U.Read(id)
    if type(id) == "number" then
      local t = M.AuraToken(id, U.Get(C_Spell and C_Spell.GetSpellName, id))
      if t and t ~= "" then
        c.tokens[t] = true
        c.token = c.token or t
      end
    end
  end
  add(info.spellID)
  add(info.overrideSpellID)
  local linked = U.Read(info.linkedSpellIDs)
  if type(linked) == "table" then
    for _, id in ipairs(linked) do
      add(id)
    end
  end
  c.name = c.sid and U.Get(C_Spell and C_Spell.GetSpellName, c.sid) or nil
  infoCache[cdID] = c
  return c
end

-- The tracked items of the buff viewers, as they are laid out now: { item, cdID, info } (pooled frames without a
-- cooldown are skipped).
function CDM.BuffItems()
  local out = {}
  for _, name in ipairs(CDM.BUFF_VIEWERS) do
    local viewer = _G[name]
    if type(viewer) == "table" and type(viewer.GetChildren) == "function" then
      for _, item in ipairs({ U.Call(viewer.GetChildren, viewer) }) do
        local cdID = type(item) == "table" and U.Read(item.cooldownID) or nil
        local info = CDM.Info(cdID)
        if info then
          out[#out + 1] = { item = item, cdID = cdID, info = info, viewer = name }
        end
      end
    end
  end
  return out
end

-- Every buff the Cooldown Manager can track for you, tracked or not: token -> { name, cdID, learned }. From the
-- game's category lists (the tracked ones, and the "not displayed" ones where the game has that category), asked
-- twice: with talents you haven't taken (greyed out in its settings) and without them (owner, 2026-11-14:
-- Starweaver's Warp and Weft were suggested but greyed out - not talented).
function CDM.Catalog()
  local cats = Enum and Enum.CooldownViewerCategory or {}
  local out, counts = {}, {}
  local get = C_CooldownViewer and C_CooldownViewer.GetCooldownViewerCategorySet
  for _, key in ipairs({ "TrackedBuff", "TrackedBar", "HiddenAura" }) do
    local cat = cats[key]
    if cat == nil and key ~= "HiddenAura" then
      cat = key == "TrackedBuff" and 2 or 3
    end
    if cat ~= nil and get then
      local n, learned = 0, 0
      for _, allowUnlearned in ipairs({ false, true }) do
        local ids = U.Get(get, cat, allowUnlearned)
        for _, cdID in ipairs(type(ids) == "table" and ids or {}) do
          local info = CDM.Info(U.Read(cdID))
          if info then
            if allowUnlearned then
              n = n + 1
            else
              learned = learned + 1
            end
            for t in pairs(info.tokens) do
              local e = out[t] or { name = info.name, cdID = cdID }
              e.learned = e.learned or not allowUnlearned
              out[t] = e
            end
          end
        end
      end
      counts[key] = n
      counts[key .. "Learned"] = learned
    end
  end
  return out, counts
end

-- The buffs your rotation checks that you don't cast yourself, most checked first: { token, id, refs }.
function CDM.KeyBuffs(record)
  if type(record) ~= "table" then
    return {}
  end
  if record._cdmKeys then
    return record._cdmKeys
  end
  local refs = {}
  local function scan(lists)
    for _, list in pairs(type(lists) == "table" and lists or {}) do
      for _, e in ipairs(type(list) == "table" and list or {}) do
        if type(e) == "table" and type(e.c) == "string" and not e.x then
          for t in e.c:gmatch("%f[%w_]buff%.([%w_]+)") do
            refs[t] = (refs[t] or 0) + 1
          end
        end
      end
    end
  end
  scan(record.simc)
  scan(record.blizzard)
  local castable, ids = {}, {}
  for id, info in pairs(record.spellInfo or {}) do
    if info.n and (info.gcd or info.ct or info.cd) and not info.pas then
      castable[info.n] = true
    end
    if info.n and (not ids[info.n] or id < ids[info.n]) then
      ids[info.n] = id
    end
  end
  local out = {}
  for t, n in pairs(refs) do
    -- a real aura in the spell data, not one of yours to cast, not someone else's
    if ids[t] and not castable[t] and not CDM.EXTERNAL[t] then
      out[#out + 1] = { token = t, id = ids[t], refs = n }
    end
  end
  table.sort(out, function(a, b)
    if a.refs ~= b.refs then
      return a.refs > b.refs
    end
    return a.token < b.token
  end)
  record._cdmKeys = out
  return out
end

local function Pretty(token)
  return (token:gsub("_", " "):gsub("(%a)([%w]*)", function(a, b)
    return a:upper() .. b
  end))
end

-- Worked out out of combat (login, spec or talent change, settings shown): on or off, what's tracked, and the key
-- buffs for your spec - tracked, "add" (the Cooldown Manager offers it) or "talent" (not taken).
function CDM.Refresh(reason)
  local st = { enabled = CDM.Enabled(), tracked = {}, trackedCount = 0, keys = {}, add = 0, have = 0, clutter = 0 }
  local state = ns.Specs and ns.Specs.current
  local record = state and state.data and ns.ActiveRecord and ns.ActiveRecord(state) or (state and state.data)
  if st.enabled then
    for _, b in ipairs(CDM.BuffItems()) do
      st.trackedCount = st.trackedCount + 1
      for t in pairs(b.info.tokens) do
        st.tracked[t] = true
      end
    end
  end
  local catalog, counts = {}, {}
  if st.enabled then
    catalog, counts = CDM.Catalog()
  end
  local catalogKnown = next(catalog) ~= nil
  local learnedKnown = false
  for _, e in pairs(catalog) do
    learnedKnown = learnedKnown or e.learned
  end
  local keySet = {}
  for _, k in ipairs(CDM.KeyBuffs(record)) do
    keySet[k.token] = true
    local rank = M.TalentRank and M.TalentRank(k.token)
    local tracked = st.tracked[k.token]
    local where
    if tracked then
      where = "tracked"
      st.have = st.have + 1
    elseif rank == 0 and not catalog[k.token] then
      where = nil -- a talent you haven't taken
    elseif catalog[k.token] and learnedKnown and not catalog[k.token].learned then
      where = nil -- offered, but greyed out: its talent isn't taken
    elseif catalog[k.token] or not catalogKnown then
      where = "add"
      st.add = st.add + 1
    else
      where = "unavailable" -- the Cooldown Manager can't track it
    end
    if where == "unavailable" then
      st.unavailable = (st.unavailable or 0) + 1 -- (logged, not listed: nothing to do about it)
    elseif where and #st.keys < CDM.KEY_MAX then
      local name = U.Get(C_Spell and C_Spell.GetSpellName, k.id) or (catalog[k.token] and catalog[k.token].name)
      st.keys[#st.keys + 1] = { token = k.token, id = k.id, name = name or Pretty(k.token), where = where,
        refs = k.refs }
    end
  end
  for t in pairs(st.tracked) do
    if not keySet[t] then
      st.clutter = st.clutter + 1
    end
  end
  st.spec = state and state.key
  CDM.status = st
  local keys = {}
  for _, k in ipairs(st.keys) do
    keys[#keys + 1] = k.token .. "=" .. k.where
  end
  local tracked = {}
  for t in pairs(st.tracked) do
    tracked[#tracked + 1] = t
  end
  table.sort(tracked)
  local viewer = _G.BuffIconCooldownViewer
  U.Log("cdm_setup", string.format("why=%s on=%s spec=%s buffs_tracked=%d [%s] key=[%s] catalog=%s alpha=%s",
    tostring(reason), tostring(st.enabled), tostring(st.spec), st.trackedCount, table.concat(tracked, ","),
    table.concat(keys, ","), (function()
      local p = {}
      for k, n in pairs(counts) do
        p[#p + 1] = k .. ":" .. n
      end
      table.sort(p)
      return table.concat(p, "/")
    end)(), tostring(type(viewer) == "table" and U.Get(viewer.GetAlpha, viewer) or "-")))
  return st
end

-- One chat line per spec and session when the Cooldown Manager is on: what DMGAssist reads from it, and how many
-- key buffs it could add. Nothing when it's off (the settings page says how to turn it on).
function CDM.Announce()
  local st = CDM.status
  if not (st and st.enabled and st.spec) or (CDM.announced or {})[st.spec] then
    return
  end
  CDM.announced = CDM.announced or {}
  CDM.announced[st.spec] = true
  local L = ns.L
  if st.add > 0 then
    U.Print(L["Cooldown Manager on: reading %d of your key buffs; %d more would help (Settings > Integrations)."],
      st.have, st.add)
  elseif st.have > 0 then
    U.Print(L["Cooldown Manager on: reading %d of your key buffs."], st.have)
  end
end

-- The settings text: on or off, and the key buffs with what to do about each.
function CDM.SettingsText()
  local L = ns.L
  local st = CDM.status
  if not InCombatLockdown or not InCombatLockdown() then
    st = CDM.Refresh("settings")
  end
  if not st or st.enabled == nil then
    return L["This game has no Cooldown Manager."]
  end
  local lines = {}
  if not st.enabled then
    lines[1] = "|cff888888" .. L["Off. Turn it on in Options > Gameplay Enhancements (Enable Cooldown Manager), "
      .. "then track the buffs below."] .. "|r"
  else
    lines[1] = "|cff33dd33" .. string.format(L["On: %d buffs tracked, %d of your key buffs among them."],
      st.trackedCount, st.have) .. "|r"
  end
  if #st.keys == 0 then
    lines[#lines + 1] = L["No key buffs for this spec: nothing to add."]
  end
  for _, k in ipairs(st.keys) do
    local text, color
    if k.where == "tracked" then
      color, text = "|cff33dd33", L["tracked"]
    elseif k.where == "add" then
      color, text = "|cffffd100", L["add it to Tracked Buffs"]
    else
      color, text = "|cff888888", L["the Cooldown Manager can't track it"]
    end
    lines[#lines + 1] = string.format("%s%s|r  -  %s", color, tostring(k.name), text)
  end
  if st.enabled and st.clutter > 0 then
    lines[#lines + 1] = "|cff888888" .. string.format(L["%d other tracked buffs: DMGAssist doesn't need them."],
      st.clutter) .. "|r"
  end
  return table.concat(lines, "\n"), #lines
end

---------------------------------------------------------------------------
-- In-fight observation: every pass, each tracked buff icon's readable parts, and when "shown" flips.
---------------------------------------------------------------------------
-- cdm_buff_summary at the end of each fight, per buff: how often each part read plainly (ok) or hidden (S), and
-- the moments its icon appeared (+) and went away (-), seconds into the fight. Checked against the combat log
-- offline (the buff's real applied/removed times), it shows whether "shown" is the proc.
CDM.FLIPS_MAX = 12
CDM.fight = nil

local function Part(rec, key, v)
  local p = rec[key]
  if not p then
    p = { ok = 0, s = 0 }
    rec[key] = p
  end
  if U.IsSecret(v) then
    p.s = p.s + 1
  elseif v ~= nil then
    p.ok = p.ok + 1
  end
end

function CDM.Observe(item, info, now, viewer)
  local f = CDM.fight
  if not f then
    return
  end
  -- per icon (the same buff tracked as an icon and as a bar is two: merged, their flips interleaved, 2026-11-14)
  local key = (info.token or tostring(info.sid)) .. (viewer == "BuffBarCooldownViewer" and "@bar" or "")
  local rec = f.buffs[key]
  if not rec then
    rec = { flips = {}, n = 0 }
    f.buffs[key] = rec
  end
  rec.n = rec.n + 1
  local shown = type(item.IsShown) == "function" and U.Call(item.IsShown, item)
  Part(rec, "sh", shown)
  Part(rec, "act", item.isActive)
  local alpha = type(item.GetAlpha) == "function" and U.Call(item.GetAlpha, item)
  Part(rec, "a", alpha)
  shown = U.Read(shown)
  if type(shown) == "boolean" and shown ~= rec.last then
    if rec.last ~= nil and #rec.flips < CDM.FLIPS_MAX then
      rec.flips[#rec.flips + 1] = string.format("%.1f%s", now - f.start, shown and "+" or "-")
    end
    rec.last = shown
  end
end

function CDM.OnCombat(inCombat)
  if inCombat then
    CDM.fight = { start = GetTime(), buffs = {} }
    return
  end
  local f = CDM.fight
  CDM.fight = nil
  if not f or not next(f.buffs) then
    return
  end
  local parts = {}
  for key, rec in pairs(f.buffs) do
    local function P(k)
      local p = rec[k] or { ok = 0, s = 0 }
      return string.format("%s=ok%d/S%d", k, p.ok, p.s)
    end
    parts[#parts + 1] = string.format("%s:%s,%s,%s flips[%s]", key, P("sh"), P("act"), P("a"),
      table.concat(rec.flips, ","))
  end
  table.sort(parts)
  U.Log("cdm_buff_summary", table.concat(parts, " "))
  if not InCombatLockdown or not InCombatLockdown() then
    CDM.Refresh("fight_end")
  end
end

-- The icon's "shown" as the buff, once it has proved right out of combat (graded against readable auras): the
-- buff icons appear when the buff does, so in combat, where isActive is hidden, "shown" may still say it.
CDM.SHOWN_MIN_CHECKS = 10
CDM.SHOWN_MAX_WRONG = 0.1
CDM.SHOWN_MIN_UP = 2 -- and seen right while the buff was up, not only "hidden, no buff"
CDM.shownStat = { checks = 0, wrong = 0, up = 0 }

function CDM.GradeShown(shown, truthUp)
  local s = CDM.shownStat
  s.checks = s.checks + 1
  if shown ~= truthUp then
    s.wrong = s.wrong + 1
  elseif truthUp then
    s.up = s.up + 1
  end
end

function CDM.ShownTrusted()
  local s = CDM.shownStat
  return s.checks >= CDM.SHOWN_MIN_CHECKS and s.up >= CDM.SHOWN_MIN_UP and s.wrong / s.checks <= CDM.SHOWN_MAX_WRONG
end
