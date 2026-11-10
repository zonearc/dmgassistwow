-- Main.lua: startup, events, the update loop, slash commands. Loaded after the generated data.

local ADDON_NAME, ns = ...
local U, L, Specs, M, S, G, D = ns.U, ns.L, ns.Specs, ns.SpellMap, ns.State, ns.Engine, ns.Display

local UPDATE_INTERVAL = 0.1

local STATUS_TEXT = {
  ready = "ready",
  no_spec = "no specialization chosen yet",
  unknown_spec = "unknown specialization",
  no_simc_list = "SimC has no priority list for this spec (healer support comes later)",
  data_not_loaded = "priority data for this client did not load",
  unsupported_client = "this game client is not supported",
}

local function Describe(state)
  if not state then
    return "not started"
  end
  local parts = {
    string.format("%s, %s %s", tostring(state.client), tostring(state.class), tostring(state.key or state.specName or "-")),
    L[STATUS_TEXT[state.status] or tostring(state.status)],
  }
  if state.starter then
    parts[#parts + 1] = L["starter spec: following Blizzard's Assisted Combat until you choose a specialization"]
  elseif state.assistedOnly then
    parts[#parts + 1] = L["no SimC list for this spec: following Blizzard's Assisted Combat"]
  elseif state.data and state.data.community then
    parts[#parts + 1] = L["no SimC list for this spec: DMGAssist's own list, learned from the class guides"]
  elseif state.source then
    parts[#parts + 1] = string.format("SimC %s %s (%s)", tostring(state.source.branch), tostring(state.source.commit),
      tostring(state.source.date))
  end
  if state.leveling then
    parts[#parts + 1] = L["leveling: following Blizzard's Assisted Combat until you know more of this spec's spells"]
  end
  return table.concat(parts, " | ")
end
ns.Describe = Describe

---------------------------------------------------------------------------
-- Spell map refresh: out of combat only (spellbook and talents can't change in combat)
---------------------------------------------------------------------------
local spellsDirty = true
local inCombat = false
local STUCK_AFTER = 3                     -- see ns.OnOwnCast
local stuck = { ignored = 0, snapped = {} }

local function RefreshSpells()
  if inCombat then
    spellsDirty = true
    return
  end
  spellsDirty = false
  M.Refresh()
  S.Calibrate()
  S.OnAura("player")
  S.OnTargetChanged()
  local state = Specs.current
  if state then
    local was = state.leveling
    ns.Leveling.Evaluate(state)
    if was ~= nil and was ~= state.leveling then
      U.Print("%s", state.leveling and L["Leveling: Blizzard's suggestions lead until you know more of this spec's spells."]
        or L["You know enough of this spec's spells now: DMGAssist's priority list leads."])
    end
  end
  ns.Leveling.OnSpellsChanged()
end

local spellRefreshPending = false
local function RequestSpellRefresh()
  if spellRefreshPending then
    return
  end
  spellRefreshPending = true
  C_Timer.After(0.3, function()
    spellRefreshPending = false
    RefreshSpells()
  end)
end

-- How much of the priority list this character can actually cast (level, talents, and on Forever: lists that SimC
-- wrote for Midnight). Logged always; told to the player when it's under half.
-- Not part of "how much of the list this character can cast": other races' racials (SimC lists carry all of them),
-- and actions that aren't spells. Counting them put a level-90 Survival at 6/13 and in leveling mode.
ns.LIST_MATCH_IGNORE = {
  arcane_torrent = true, berserking = true, blood_fury = true, fireblood = true, ancestral_call = true,
  bag_of_tricks = true, lights_judgment = true, arcane_pulse = true, war_stomp = true, shadowmeld = true,
  rocket_barrage = true, haymaker = true, azerite_surge = true, retarget = true, summon_pet = true,
  call_pet = true, invoke_external_buff = true, use_item = true,
}

function ns.ListMatch(state)
  local record = state and state.data
  if not (record and record.simc) then
    return nil
  end
  local seen, have, total, missing = {}, 0, 0, {}
  for _, list in pairs(record.simc) do
    for _, e in ipairs(list) do
      local a = e.a
      if not G.SKIP[a] and not ns.LIST_MATCH_IGNORE[a] and not seen[a] then
        seen[a] = true
        total = total + 1
        if M.SpellID(a) then
          have = have + 1
        else
          missing[#missing + 1] = a
        end
        M.unresolved[a] = nil
      end
    end
  end
  table.sort(missing)
  return have, total, missing
end

Specs.OnChange(function(state, previous)
  M.SetData(state.data)
  if state.key then
    S.Bind(state.key)
  end
  RefreshSpells()
  local have, total, missing = ns.ListMatch(state)
  if have then
    local gm = state.data.gameMatch
    U.Log("list_match", { spec = state.key, have = have, total = total, gameData = gm and (gm.matched .. "/" .. gm.total),
      source = state.data.simcSource, missing = table.concat(missing, ","):sub(1, 150) })
    if total >= 5 and have / total < 0.5 and not state.leveling and not state.assistedOnly then
      U.Print(L["Only %d of %d spells in this priority list are in your spellbook. Recommendations use what you have, "
        .. "so expect gaps (low level, talents, or a list written for another game version)."], have, total)
    end
  end
  if previous then
    U.Print(L["Spec changed: %s"], Describe(state))
  end
end)

---------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------
ns.last = nil
local lastLogged

-- Preview: while the settings panel is open, or the HUD is unlocked out of combat, it is shown even without a
-- target so it can be placed and styled.
function ns.Previewing()
  if inCombat then
    return false
  end
  if ns.Integrations.editMode then
    return true -- Blizzard's Edit Mode: shown with everything else so it can be placed
  end
  if ns.db and ns.db.locked == false and ns.db.previewUnlocked ~= false then
    return true
  end
  return SettingsPanel ~= nil and U.Get(SettingsPanel.IsShown, SettingsPanel) == true
end

local function Hidden()
  local cfg = D.Settings()
  if U.Get(C_PetBattles and C_PetBattles.IsInBattle) == true then
    return true
  end
  if cfg.hideVehicle and U.Get(UnitInVehicle, "player") == true then
    return true
  end
  if cfg.hideMounted and not inCombat and U.Get(IsMounted) == true then
    return true
  end
  return false
end

local function ShouldShow()
  if not (ns.db and ns.db.enabled ~= false) then
    return false
  end
  if ns.Previewing() then
    return true
  end
  if Hidden() or ns.Choices.SpecOff() then
    return false
  end
  local enemy = U.Get(UnitExists, "target") == true and
    U.Get(UnitCanAttack, "player", "target") == true
  -- A missing buff before the pull is worth showing even when the HUD hides out of combat.
  return D.ShouldShow(inCombat, enemy) or (not inCombat and ns.Buffs.Missing() ~= nil)
end

-- What is going on right now, as label / value pairs, for the Status page in the settings.
ns.LINKS = {
  home = "https://github.com/zonearc/dmgassistwow",
  curseforge = "https://www.curseforge.com/wow/addons/dmgassist",
  issues = "https://github.com/zonearc/dmgassist-issues/issues",
  downloads = "https://github.com/zonearc/dmgassistwow/releases/tag/nightly",
}

function ns.StatusLines()
  local state = Specs.current or {}
  local out = {}
  local function add(label, value)
    out[#out + 1] = { L[label], tostring(value) }
  end
  add("Version", ns.VERSION .. (ns.TESTING and " (test build)" or ""))
  add("Game", tostring(state.client or "?"))
  add("Class and spec", string.format("%s, %s", tostring(state.class or "?"), tostring(state.specName or state.key
    or "-")))
  add("Status", L[STATUS_TEXT[state.status] or tostring(state.status or "?")])
  if state.data then
    local have, total = ns.ListMatch(state)
    local src = state.data.simcSource == "wowsims" and "WoWSims" or "SimulationCraft"
    add("Rotation from", src .. (state.source and (" " .. tostring(state.source.commit) .. ", " ..
      tostring(state.source.date)) or ""))
    if have then
      add("Rotation spells known", string.format("%d of %d", have, total))
    end
  end
  local n, label = S.Targets()
  add("Target mode", string.format("%s (%s targets now)", tostring(label), tostring(n)))
  local key = U.Get(GetBindingKey, "DMGASSIST_CYCLEMODE")
  add("Key to switch target mode", type(key) == "string" and key or L["none set (Settings > DMGAssist > Set key bindings)"])
  local specAoe = S.SpecAoeTargets(state.data)
  if ns.db.aoeCount == "custom" then
    add("AoE target count", string.format("%d (custom)", S.AoeTargets()))
  else
    add("AoE target count", specAoe and string.format("%d (your spec's switch point)", specAoe)
      or L["3 (your spec's list weighs the count line by line)"])
  end
  local context = S.fightContext or S.FightContext()
  local learned = S.LearnedFightLength(context)
  local mode = ns.db.fightMode or "learned"
  add("Fight length", string.format("%d s (%s, %s)", S.FightLength(), mode == "learned" and (learned and
    L["learned"] or L["learning (SimC default until then)"]) or mode, context))
  local mods = ns.BossMods.Detected()
  add("Boss mods found", #mods > 0 and table.concat(mods, ", ") or L["none"])
  local keys = 0
  for _ in pairs(D.BuildKeymap()) do
    keys = keys + 1
  end
  add("Keybinds found", keys)
  local ac = C_AssistedCombat and U.Get(C_AssistedCombat.IsAvailable)
  add("Blizzard's assisted combat", ac == true and L["available (used as a second opinion)"] or L["not available"])
  add("Talents loaded", M.talentsRead and L["yes"] or L["no"])
  add("Interrupt spell", tostring(D.InterruptSpell() and U.Get(C_Spell and C_Spell.GetSpellName, D.InterruptSpell())
    or "-"))
  add("Other addons in use", ns.Integrations.InUse() or L["none"])
  add("Watchdog (diagnostics)", type(_G.DMGAssistWatchdog) == "table" and L["installed"] or L["not installed"])
  return out
end

-- What DMGAssist looked like at launch (the Watchdog records the rest of the environment).
function ns.LogLaunchState()
  local state = Specs.current or {}
  local have, total = ns.ListMatch(state)
  local keys = 0
  for _ in pairs(D.BuildKeymap()) do
    keys = keys + 1
  end
  U.Log("launch_state", {
    version = ns.VERSION, testing = ns.TESTING, client = state.client, spec = state.key, status = state.status,
    data = state.source and (state.source.branch .. "@" .. tostring(state.source.commit)), listSource = state.data
      and state.data.simcSource, spellsMatched = M.count, listMatch = have and (have .. "/" .. total),
    talentsRead = M.talentsRead, bossMods = table.concat(ns.BossMods.Detected(), ","), keybinds = keys,
    interrupt = D.InterruptSpell(), defensive = (ns.Defensives.Spell()), haste = S.hasteSource,
  })
  local settings = {}
  for k, v in pairs(ns.db or {}) do
    if type(v) ~= "table" then
      settings[#settings + 1] = k .. "=" .. tostring(v)
    end
  end
  for k, v in pairs(D.Settings()) do
    settings[#settings + 1] = "hud." .. k .. "=" .. tostring(v)
  end
  table.sort(settings)
  U.Log("launch_settings_summary", table.concat(settings, " "))
end

-- Sounds on the rising edge of each alert (each event is also throttled in Sounds).
local alerted = {}
function ns.Alerts(result)
  local intr = result.interrupt and result.interrupt.how == "decided"
  if intr and not alerted.interrupt then
    ns.Sounds.Play("interrupt")
  end
  alerted.interrupt = intr
  local call = result.callout and not result.callout.seconds and result.callout.kind or nil
  if call and call ~= alerted.call then
    ns.Sounds.Play("bosscall")
  end
  alerted.call = call
  local cd = result.main and result.main.major and result.main.id or nil
  if cd and cd ~= alerted.cd then
    ns.Sounds.Play("burst")
  end
  alerted.cd = cd
end

-- The record to use right now. Forever Feral switches to the bear list in Bear Form (record.alternate): the form
-- ID when readable (GetShapeshiftFormID, DRUID_BEAR_FORM = 5 in Blizzard's UI), else whether Maul (bear-only)
-- can be cast.
local activeRecord
function ns.ActiveRecord(state)
  local record = state.data
  local alt = record and record.alternate
  if alt then
    local inForm
    local form = U.Get(GetShapeshiftFormID)
    if type(form) == "number" then
      inForm = form == alt.form
    else
      local probe = M.SpellID(alt.probe)
      M.unresolved[alt.probe] = nil
      local usable, noPower = U.Call(C_Spell and C_Spell.IsSpellUsable, probe or 0)
      inForm = probe ~= nil and (U.Read(usable) == true or U.Read(noPower) == true)
    end
    local other = inForm and ns.Data.Get(state.branch, alt.key)
    if other then
      record = other
    end
  end
  if record ~= activeRecord then
    activeRecord = record
    M.SetData(record)
  end
  return record
end

-- Major cooldowns: off, always (default), or only for bosses, PvP and big pulls (optional, "bigOnly").
ns.BIG_PULL = 5
function ns.BurstAllowed()
  if ns.db.burst == false then
    return false
  end
  if ns.db.burstWhen ~= "big" then
    return true
  end
  local context = S.FightContext()
  if context == "boss" or context == "pvp" then
    return true
  end
  local n = S.Targets()
  return (tonumber(n) or 0) >= (tonumber(ns.db.bigPull) or ns.BIG_PULL)
end

local function Update()
  local state = Specs.current
  if not state or state.status ~= "ready" or not state.data then
    D.Update(nil, false)
    return nil
  end
  if spellsDirty and not inCombat then
    RefreshSpells()
  end
  D.MaybeRefreshKeymap(inCombat)
  ns.Bindcheck.MaybeNotice(inCombat)
  ns.Diagnostics.Tick()
  local show = ShouldShow()
  -- the settings window is open: dock the HUD beside it as a live preview (see Display.lua)
  local settingsOpen = not inCombat and SettingsPanel ~= nil and U.Get(SettingsPanel.IsShown, SettingsPanel) == true
  D.SetPreviewDock(settingsOpen and show)
  if not show then
    D.Update(nil, false)
    return nil
  end
  S.VerifyPowers()
  ns.Clues.ReadCooldownManager(S.ReadableAuras())
  local result = G.Recommend(ns.ActiveRecord(state), {
    burst = ns.BurstAllowed(),
    useAssisted = (state.branch == "midnight" or state.assistedOnly or state.leveling) and ns.db.useAssisted ~= false,
  })
  result.callout = ns.BossMods.Callout()
  G.Steady(result)
  if state.leveling then
    ns.Leveling.Lead(result, ns.ActiveRecord(state)) -- Blizzard's pick in slot 1, the priority list after it
  end
  G.PromoteReadyMajor(result) -- a ready major cooldown never waits behind Blizzard's pick, on any path
  ns.Essentials.Apply(result)
  ns.Trinkets.Apply(result)
  ns.Buffs.Apply(result) -- before interrupts and defensives: those always take slot 1
  ns.Interrupts.Apply(result)
  ns.Defensives.Apply(result)
  ns.Choices.Filter(result)
  ns.Alerts(result)
  ns.Diagnostics.OnPick(result)
  if settingsOpen then
    -- preview: both small icons shown, so their position and size can be set
    result.weave = result.weave or D.SAMPLE_DEFENSIVE
    result.trinket = result.trinket or D.SAMPLE_ITEM
  end
  ns.last = result
  ns.NoteShown(result.main)
  ns.Bindcheck.OnShown(result.main)
  D.Update(result, not ns.Integrations.hudHidden)
  ns.Integrations.OnRecommendation(result)
  -- Decision log: one line per change of pick (not every tick).
  local main = result.main
  local cd = main and main.major and main or nil
  local q2, q3 = result.queue and result.queue[2], result.queue and result.queue[3]
  local sig = (main and (main.token or main.id) or "-") .. "/" .. (cd and cd.token or "-") .. "/" ..
    tostring(result.modeLabel) .. "/" .. tostring(result.trinket and result.trinket.token)
  if sig ~= lastLogged then
    lastLogged = sig
    if inCombat then
      -- Why this pick: the same decision again with every line traced (one per change, capped per fight).
      S.unknownTerms = {}
      local traced = G.Recommend(ns.ActiveRecord(state), { burst = ns.BurstAllowed(), trace = true,
        useAssisted = (state.branch == "midnight" or state.assistedOnly or state.leveling) and ns.db.useAssisted ~= false })
      ns.Diagnostics.Trace(result, traced.trace)
    end
    U.Log("pick", {
      main = main and main.token, source = main and main.source, cd = cd and cd.token, ac = result.acSpell,
      next = q2 and q2.token, after = q3 and q3.token, mode = result.modeLabel, held = result.steadied,
      trinket = result.trinket and result.trinket.token or nil, weave = result.weave and result.weave.token or nil,
    })
  end
  return result
end

-- One update is one pass: values that cannot change inside it (the enemy count) are read once.
function ns.Update()
  S.BeginPass()
  local result = Update()
  S.EndPass()
  return result
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------
local SPELL_EVENTS = { SPELLS_CHANGED = true, TRAIT_CONFIG_UPDATED = true, PLAYER_TALENT_UPDATE = true,
  ACTIVE_TALENT_GROUP_CHANGED = true, PLAYER_LEVEL_UP = true }

local frame = CreateFrame("Frame")
ns.eventFrame = frame
for _, event in ipairs({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_DISABLED",
  "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED", "UI_ERROR_MESSAGE", "SPELL_UPDATE_COOLDOWN", "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
  "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" }) do
  frame:RegisterEvent(event)
end
-- Keybind text on the icons follows action bar and binding changes.
local KEYBIND_EVENTS = { ACTIONBAR_SLOT_CHANGED = true, UPDATE_BINDINGS = true, ACTIONBAR_PAGE_CHANGED = true,
  UPDATE_BONUS_ACTIONBAR = true, UPDATE_MACROS = true, UPDATE_SHAPESHIFT_FORM = true,
  PLAYER_EQUIPMENT_CHANGED = true }
for event in pairs(KEYBIND_EVENTS) do
  pcall(frame.RegisterEvent, frame, event)
end
for _, event in ipairs(Specs.EVENTS) do
  if event == "PLAYER_SPECIALIZATION_CHANGED" then
    pcall(frame.RegisterUnitEvent, frame, event, "player")
  else
    pcall(frame.RegisterEvent, frame, event)
  end
end
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_SUCCEEDED", "player")
pcall(frame.RegisterUnitEvent, frame, "UNIT_POWER_UPDATE", "player")
pcall(frame.RegisterEvent, frame, "PLAYER_STARTED_MOVING")
pcall(frame.RegisterEvent, frame, "PLAYER_STOPPED_MOVING")
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_START", "target", "player")
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_CHANNEL_START", "target", "player")
for _, event in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_INTERRUPTED", "UNIT_SPELLCAST_FAILED",
  "UNIT_SPELLCAST_FAILED_QUIET", "UNIT_SPELLCAST_CHANNEL_STOP", "UNIT_SPELLCAST_EMPOWER_START",
  "UNIT_SPELLCAST_EMPOWER_STOP" }) do
  pcall(frame.RegisterUnitEvent, frame, event, "player")
end
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELL_HASTE", "player")
for _, event in ipairs({ "SPELL_UPDATE_USABLE", "SPELL_UPDATE_ICON", "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED",
  "ENCOUNTER_START", "ENCOUNTER_END" }) do
  pcall(frame.RegisterEvent, frame, event)
end
pcall(frame.RegisterUnitEvent, frame, "UNIT_AURA", "player", "target")

local DEFAULTS = { enabled = true, burst = true,
  burstWhen = "always", bigPull = 5, skipHold = true, ironfurStacks = 3, tankEssentials = true,
  gapClosers = true, trinkets = true, bindWarn = true, buffReminders = true,
  levelingMode = "auto", levelNotices = true, healAt = 35, healInRaids = false,
  atonementRamp = true, atonementTarget = 5, atonementLead = 8, healSupport = false, atonementKeep = 3,
  huntersMark = true,
  mode = "aoe", autoDetect = true, aoeTargets = 3, fightLength = 300,
  useAssisted = true, queue = 3, smartFight = true, fightMode = "learned", aoeCount = "spec", bossMods = true, interruptMode = "smart",
  defensiveMode = "smart", defensiveHealth = 35, defensiveLead = 3, sounds = true, locked = true,
  minimap = true, minimapAngle = 220 }
ns.DEFAULTS = DEFAULTS

frame:SetScript("OnEvent", function(_, event, ...)
  local arg1, _, arg3 = ...
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      ns.Profiles.Load(DEFAULTS) -- ns.db: this character's profile (shared "Default" unless chosen otherwise)
      ns.ApplyLanguage()
      ns.Sounds.Migrate()
      ns.Client.Detect()
    end
    ns.BossMods.Hook() -- boss mods can load before us, after us, or on demand
    D.InvalidateKeybinds() -- a bar addon may have just loaded
  elseif event == "PLAYER_LOGIN" then
    ns.Minimap.Apply()
    local state = Specs.Refresh("login")
    U.Print("%s", Describe(state))
    local loaded = ns.Data.LoadedBranches()
    if #loaded > 1 then
      U.Print(L["Warning: data for %s loaded at once; using %s."], table.concat(loaded, " and "), tostring(state.branch))
      U.Log("data_gating", table.concat(loaded, ","))
    end
    D.Create()
    ns.Integrations.Setup()
    ns.Options.Register()
    ns.BossMods.Hook()
    C_Timer.After(5, ns.LogLaunchState)
    C_Timer.After(3, ns.Welcome.MaybeAsk)
  elseif KEYBIND_EVENTS[event] then
    D.InvalidateKeybinds()
    if event == "PLAYER_EQUIPMENT_CHANGED" then
      S.ForgetTalentCache() -- set bonuses come and go with gear
    end
  elseif event == "PLAYER_REGEN_DISABLED" then
    inCombat = true
    stuck.ignored, stuck.snapped = 0, {}
    lastLogged = nil -- the first pick of every fight is logged (and traced)
    S.OnCombat(true)
    ns.Essentials.Reset()
    ns.Engine.OnCombat()
    ns.Diagnostics.OnCombat(true)
    ns.Grade.OnCombat(true)
    if ns.TESTING then
      -- test builds: one decision snapshot a few seconds into every fight, without chat output
      C_Timer.After(3, function()
        if inCombat then
          pcall(ns.QuietSnapshot)
        end
      end)
    end
  elseif event == "PLAYER_REGEN_ENABLED" then
    inCombat = false
    S.OnCombat(false)
    ns.Options.OnCombatEnded() -- after the combat flags clear
    ns.Engine.OnCombat()
    ns.Grade.OnCombat(false) -- before the fight's log closes, so the grade is in reports
    ns.Diagnostics.OnCombat(false)
    S.Calibrate()
    if spellsDirty then
      RequestSpellRefresh()
    end
    ns.Leveling.OnCombatEnd()
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if arg1 == "player" then
      S.OnSpellcastSucceeded(arg3)
    end
  elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START"
    or event == "UNIT_SPELLCAST_EMPOWER_START" then
    if arg1 == "player" then
      S.OnOwnCastStart(arg3, event ~= "UNIT_SPELLCAST_START")
      ns.OnOwnCastStart(U.Read(arg3))
    else
      ns.Interrupts.OnTargetCastStart()
    end
  elseif event == "UNIT_SPELLCAST_STOP" then
    S.OnOwnCastEnded() -- the bar ended; SUCCEEDED (before or after) still matches it
  elseif event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
    S.OnCastFailed(arg3) -- pressed before it was ready: State.lua "pressing until it goes through"
    if event == "UNIT_SPELLCAST_FAILED" then
      S.OnOwnCastStop(nil)
    end
  elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP"
    or event == "UNIT_SPELLCAST_EMPOWER_STOP" then
    S.OnOwnCastStop(nil)
  elseif event == "PLAYER_STARTED_MOVING" then
    S.moving = true
  elseif event == "PLAYER_STOPPED_MOVING" then
    S.moving = false
  elseif event == "UNIT_POWER_UPDATE" then
    ns.Clues.OnPowerEvent(U.Read(select(2, ...)))
  elseif event == "UNIT_SPELL_HASTE" then
    S.OnHasteChanged()
  elseif event == "SPELL_UPDATE_USABLE" then
    -- fires many times a second (every resource tick): scan at most 10x per second
    local now = GetTime()
    if now - (ns.lastUsableScan or 0) >= 0.1 then
      ns.lastUsableScan = now
      ns.Clues.ScanRequirements(S.AurasReadable())
    end
  elseif event == "SPELL_UPDATE_ICON" or event == "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED" then
    ns.Clues.ScanOverrides(S.AurasReadable())
  elseif event == "ENCOUNTER_START" then
    S.inEncounter = true
  elseif event == "ENCOUNTER_END" then
    S.inEncounter = false
    ns.BossMods.Reset()
  elseif event == "SPELL_UPDATE_COOLDOWN" then
    S.OnCooldownUpdate()
  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW" then
    S.OnGlow(arg1, true)
  elseif event == "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" then
    S.OnGlow(arg1, false)
  elseif event == "UNIT_AURA" then
    S.OnAura(U.Read(arg1))
    ns.Buffs.Invalidate()
  elseif event == "UI_ERROR_MESSAGE" then
    S.OnUIError(U.Read(arg1), U.Read(select(2, ...)))
  elseif event == "PLAYER_TARGET_CHANGED" then
    S.OnTargetChanged()
    ns.Essentials.OnTargetChanged()
    ns.Interrupts.OnTargetCastStart()
  else
    Specs.RequestRefresh(event)
    if SPELL_EVENTS[event] then
      RequestSpellRefresh()
    end
    if event == "PLAYER_LEVEL_UP" then
      ns.Leveling.OnLevelUp()
    end
  end
end)

local elapsed = 0
frame:SetScript("OnUpdate", function(_, dt)
  elapsed = elapsed + (dt or 0)
  if elapsed < UPDATE_INTERVAL then
    return
  end
  elapsed = 0
  local ok, err = pcall(ns.Update)
  if not ok then
    U.Log("engine_error", U.Safe(err))
    if ns.TESTING and not ns.shownEngineError then
      ns.shownEngineError = true
      U.Print("Engine error (logged for the Watchdog; shown once per session): %s", tostring(U.Safe(err)))
    end
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local commands = {}
ns.commands = commands -- the minimap menu uses the same actions as the slash commands

-- /dmga potion <shift-click a potion>: the potion shown in the items icon for this spec; /dmga potion off clears it.
function commands.potion(arg)
  local item = tonumber((arg or ""):match("item:(%d+)") or arg)
  if arg == "off" or arg == "none" then
    ns.Trinkets.SetPotion(nil)
    U.Print("%s", L["Potion removed for this spec."])
  elseif item then
    ns.Trinkets.SetPotion(item)
    U.Print(L["Potion set for this spec: %s."], tostring(arg:match("%[(.-)%]") or item))
  else
    U.Print("%s", L["Type /dmga potion and shift-click a potion to choose it."])
  end
end

-- /dmga addons: which supported addons are installed and in use.
function commands.addons()
  ns.Integrations.PrintDetected()
end

-- /dmga relearn: forget learned cooldown timing (also in Settings).
function commands.relearn()
  if S.ResetLearning() then
    U.Print(L["Learned cooldown timing forgotten. DMGAssist learns again from your next fight."])
  else
    U.Print(L["Not in combat: try again after the fight."])
  end
end

function commands.on()
  ns.db.enabled = true
  U.Print(L["Recommendations on."])
end

function commands.off()
  ns.db.enabled = false
  D.Update(nil, false)
  U.Print(L["Recommendations off."])
end

function commands.burst()
  ns.db.burst = ns.db.burst == false
  U.Print(ns.db.burst and L["Major cooldowns on."] or L["Major cooldowns off."])
end

-- /dmga mode st|aoe sets the primary mode; /dmga mode alone cycles like the hotkey.
function commands.mode(arg)
  if arg == "st" or arg == "aoe" then
    ns.db.mode = arg
    S.modeOverride = nil
  elseif arg == "auto" then
    ns.db.autoDetect = true
    S.modeOverride = nil
  else
    S.CycleMode()
  end
  local _, label = S.Targets()
  U.Print(L["Target mode: %s."], (label:gsub("%a+", function(w) return L[w] end)))
end

function commands.auto(arg)
  if arg == "on" then
    ns.db.autoDetect = true
  elseif arg == "off" then
    ns.db.autoDetect = false
  else
    ns.db.autoDetect = ns.db.autoDetect == false
  end
  S.modeOverride = nil
  U.Print(ns.db.autoDetect and L["Auto-detect targets: on."] or L["Auto-detect targets: off."])
end

function commands.targets(arg)
  local n = tonumber(arg)
  if n and n >= 1 then
    ns.db.aoeTargets = math.floor(n)
    ns.db.aoeCount = "custom" -- a number typed in means "use this", not the spec's switch point
  end
  U.Print(L["AoE targets: %d."], S.AoeTargets())
end

function commands.fight(arg)
  local n = tonumber(arg)
  if n and n >= 10 then
    ns.db.fightLength = math.floor(n)
  end
  U.Print(L["Assumed fight length: %ds."], ns.db.fightLength)
end

function commands.queue(arg)
  local n = tonumber(arg)
  if n and n >= 1 and n <= 3 then
    ns.db.queue = math.floor(n)
  end
  U.Print(L["Queue length: %d."], tonumber(ns.db.queue) or 3)
end

function commands.lock()
  ns.db.locked = not ns.db.locked
  D.SetLocked(ns.db.locked)
  D.Rebuild()
  U.Print(ns.db.locked and L["Icon locked."] or L["Icon unlocked (drag to move)."])
end

-- Tests for the integrations (also buttons in Settings > Integrations), so players can see each one work.
local function SpellName(id)
  return id and U.Get(C_Spell and C_Spell.GetSpellName, id) or L["none available"]
end

function commands.test(arg)
  if arg == "interrupt" or arg == "kick" then
    ns.Interrupts.testUntil = GetTime() + 8
    U.Print(L["Interrupt test: slot 1 shows %s for 8 seconds."],
      tostring(SpellName(ns.Display.InterruptSpell())))
  elseif arg == "assisted" then
    local ac = U.Get(C_AssistedCombat and C_AssistedCombat.GetNextCastSpell, false)
    if type(ac) == "number" then
      U.Print(L["Blizzard's Assisted Combat suggests %s right now: it is working."], tostring(SpellName(ac)))
    else
      U.Print("%s", L["Blizzard's Assisted Combat gives no suggestion here (Forever has none; on Midnight target "
        .. "an enemy and try again)."])
    end
  elseif arg == "bossmods" then
    local mods = ns.BossMods.Detected()
    if #mods > 0 then
      U.Print(L["Boss mods found: %s. Their timers and calls are used for defensives and interrupts."],
        table.concat(mods, ", "))
    else
      U.Print("%s", L["No boss mod found (DBM, BigWigs, LittleWigs). Defensives then follow your health only."])
    end
  else
    ns.BossMods.Test("defensive", 8)
    U.Print(L["Defensive test: slot 1 shows %s for 8 seconds."],
      tostring(SpellName(ns.Defensives.Spell())))
  end
end

function commands.report()
  ns.OpenReport()
end
commands.issue = commands.report
commands.feedback = commands.report

-- /dmga spec on|off: DMGAssist on or off for the spec you are in (toggles without an argument).
function commands.spec(arg)
  local off
  if arg == "off" then
    off = true
  elseif arg == "on" then
    off = false
  else
    off = not ns.Choices.SpecOff()
  end
  ns.Choices.SetSpecOff(off)
  local state = Specs.current
  U.Print(off and L["DMGAssist is off for %s. /dmga spec on turns it back on."] or L["DMGAssist is on for %s."],
    tostring(state and (state.specName or state.key) or "?"))
  ns.Update()
end

function commands.welcome()
  ns.Welcome.Open()
end
commands.setup = commands.welcome

function commands.unbound()
  D.BuildKeymap()
  ns.Bindcheck.Print()
end

function commands.keys()
  local map = D.BuildKeymap()
  local n = 0
  for _ in pairs(map) do
    n = n + 1
  end
  U.Print(L["Keybinds refreshed: %d spells on your bars."], n)
end

-- Full decision trace for troubleshooting: every line looked at, castable or not and
-- why, its condition result, the inputs that were unknown; printed short in chat and stored in the Watchdog log.
-- "Stuck" detector: the HUD keeps showing one spell while the player casts other things. After 3 such casts
-- in a row a full decision snapshot is stored (once per spell per fight), so a report shows why it stuck.
-- One button press can report several casts: Rampage reports 3 (184707, 184367, 184709), Whirlwind and Raging
-- Blow 2-3, all at the same moment. Only one of them is the ability you pressed; the rest are its hits. The skip
-- rule and the stuck detector count presses, not those pieces (2026-11-09: one Rampage and one Whirlwind added up
-- to "skipped Odyn's Fury three times", and it was held for the rest of the fight).
local lastPress = 0
local function IsPress(id)
  local now = GetTime()
  if now - lastPress < 0.1 then
    return false -- another piece of the same press
  end
  local known = U.Get(IsPlayerSpell, id) == true or (ns.SpellMap.book and ns.SpellMap.book[id] ~= nil)
  if known then
    lastPress = now
  end
  return known
end
ns.IsPress = IsPress

-- What slot 1 showed when a press was decided. The cast event comes after the press: an instant lands a frame or
-- two later, a cast-time spell when its bar ends. If slot 1 changed in between, the latest pick is not what you were
-- looking at (2026-11-10, Balance: Starfall and Starfire landed 50 ms after slot 1 flipped to Eclipse; three such
-- "skips" held Eclipse for the rest of the fight). A cast matching anything slot 1 showed since the press counts.
local shownLog, castStart = {}, nil
ns.PRESS_WINDOW = 0.35 -- seconds before an instant's cast event that its press may have been decided
function ns.NoteShown(main)
  local last = shownLog[#shownLog]
  if main and main.id and not (last and last.main.id == main.id) then
    shownLog[#shownLog + 1] = { t = GetTime(), main = main }
    if #shownLog > 16 then
      table.remove(shownLog, 1)
    end
  end
end

function ns.OnOwnCastStart(id)
  castStart = { id = id, t = GetTime() }
end

function ns.ShownForPress(id)
  local now, baseOf = GetTime(), ns.SpellMap.baseOf or {}
  local from = now - ns.PRESS_WINDOW
  if castStart and castStart.id == id and now - castStart.t < 10 then
    from = math.min(from, castStart.t)
  end
  local base = baseOf[id] or id
  for i = #shownLog, 1, -1 do
    local e = shownLog[i]
    local after = shownLog[i + 1]
    if not after or after.t >= from then -- on screen at some point since the press
      if (baseOf[e.main.id] or e.main.id) == base then
        return e.main
      end
    end
    if e.t <= from then
      return e.main -- what slot 1 showed when the press was decided
    end
  end
  return ns.last and ns.last.main
end

function ns.OnOwnCast(id)
  local shown = ns.ShownForPress(id)
  ns.Essentials.OnOwnCast(id)
  ns.Trinkets.OnOwnCast(id)
  local press = IsPress(id)
  if inCombat then
    ns.Grade.OnPress(id, ns.last, press)
  end
  if not press then
    return
  end
  if inCombat then
    local what, spell = G.OnPlayerCast(id, shown, ns.db.skipHold ~= false, ns.last and ns.last.queue)
    if what then
      U.Log(what == "held" and "hold" or "hold_released", { spell = spell, cast = id })
    end
  end
  if not (inCombat and shown and shown.id) then
    return
  end
  if id == shown.id or (ns.SpellMap.baseOf[id] and ns.SpellMap.baseOf[id] == shown.id) then
    stuck.ignored = 0
    return
  end
  stuck.ignored = stuck.ignored + 1
  if stuck.ignored >= STUCK_AFTER and not stuck.snapped[shown.id] then
    stuck.snapped[shown.id] = true
    U.Log("stuck", { shown = shown.token, source = shown.source, castInstead = id, casts = stuck.ignored })
    pcall(ns.QuietSnapshot)
  end
end

function ns.QuietSnapshot()
  ns.snapshotQuiet = true
  commands.snapshot()
  ns.snapshotQuiet = false
end

function commands.snapshot()
  local state = Specs.current
  if not (state and state.data) then
    U.Print(L["No recommendation right now."])
    return
  end
  S.unknownTerms = {}
  local r = G.Recommend(ns.ActiveRecord(state), { burst = ns.BurstAllowed(), trace = true,
    useAssisted = (state.branch == "midnight" or state.assistedOnly or state.leveling) and ns.db.useAssisted ~= false })
  local lines = r.trace or {}
  U.Log("snapshot", { spec = state.key, pick = r.main and r.main.token, source = r.main and r.main.source,
    lines = #lines, mode = r.modeLabel })
  for i, line in ipairs(lines) do
    U.Log("snapshot_line", i .. " " .. line)
  end
  local unknown = {}
  for name, n in pairs(S.unknownTerms) do
    unknown[#unknown + 1] = name .. "x" .. n
  end
  table.sort(unknown)
  U.Log("snapshot_unknown", table.concat(unknown, " "))
  if ns.snapshotQuiet then
    return
  end
  U.Print(L["Snapshot: %s (%s), %d lines checked. Stored for your report: /dmga report."],
    tostring(r.main and r.main.token), tostring(r.main and r.main.source), #lines)
  for i = 1, math.min(#lines, 8) do
    U.Print("  %s", lines[i])
  end
end

function commands.config()
  ns.Options.Open()
end
commands.options = commands.config

function commands.why()
  local r = ns.last
  if not r or not r.main then
    U.Print(L["No recommendation right now."])
    return
  end
  local names = {}
  for i, pick in ipairs(r.queue or {}) do
    names[i] = tostring(pick.token)
  end
  U.Print(L["Next: %s (%s). Assisted Combat says: %s."], table.concat(names, " > "),
    tostring(r.main.source), tostring(r.acSpell or "-"))
  local missing = {}
  for name in pairs(r.unresolved or {}) do
    missing[#missing + 1] = name
  end
  table.sort(missing)
  if #missing > 0 then
    U.Print(L["Spells in the list you don't have (or we can't match): %s"], table.concat(missing, ", "))
  end
end

function commands.help()
  U.Print(L["Commands:"])
  local lines = {
    { "/dmga", "status" },
    { "/dmga on | off", "show or hide recommendations" },
    { "/dmga burst", "toggle major cooldowns" },
    { "/dmga mode st | aoe", "primary target mode" },
    { "/dmga mode", "cycle Auto / Single / AoE (also a key binding)" },
    { "/dmga auto on | off", "auto-detect targets from nameplates" },
    { "/dmga targets <n>", "targets assumed in AoE mode" },
    { "/dmga fight <seconds>", "assumed fight length" },
    { "/dmga queue 1-3", "icons shown (1-3)" },
    { "/dmga lock", "lock or unlock the icon position" },
    { "/dmga why", "explain the current pick" },
    { "/dmga config", "open the settings panel" },
    { "/dmga keys", "refresh keybinds" },
    { "/dmga report", "report an issue or give feedback: describe it, copy the report, open the issue page" },
    { "/dmga spec on|off", "DMGAssist on or off for the spec you are in (an alt's healing spec, for example)" },
    { "/dmga welcome", "the three setup questions again (where, how big, when to show)" },
    { "/dmga unbound", "list recommended spells that have no keybind" },
    { "/dmga test", "test the defensive alert (8 seconds)" },
    { "/dmga test interrupt | assisted | bossmods", "test the interrupt alert, Assisted Combat, or boss mod detection" },
    { "/dmga snapshot", "save a full decision trace for troubleshooting" },
    { "/dmga relearn", "forget learned cooldown timing and start learning again" },
    { "/dmga addons", "which supported addons (Masque, ElvUI, Bartender, boss mods...) are found and in use" },
    { "/dmga potion", "choose the potion for this spec (shift-click it), or /dmga potion off" },
  }
  for _, line in ipairs(lines) do
    U.Print("%s — %s", line[1], L[line[2]])
  end
end

-- Key bindings (Bindings.xml) call these globals.
function DMGAssist_CycleMode()
  commands.mode("")
end

function DMGAssist_ToggleBurst()
  commands.burst()
end

function DMGAssist_Toggle()
  if ns.db.enabled == false then
    commands.on()
  else
    commands.off()
  end
end

SLASH_DMGASSIST1 = "/dmga"
SLASH_DMGASSIST2 = "/dmgassist"
SlashCmdList.DMGASSIST = function(msg)
  local cmd, arg = tostring(msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
  if commands[cmd] then
    commands[cmd](arg)
    return
  end
  local state = Specs.Refresh("slash")
  U.Print("%s", Describe(state))
  U.Print(L["Spells matched: %s. Type /dmga help for options."], tostring(M.count or 0))
  if state.data and state.data.credit then
    U.Print(L["Rotation by %s."], state.data.credit)
  end
  local mods = ns.BossMods.Detected()
  if #mods > 0 then
    U.Print(L["Boss mods: %s."], table.concat(mods, ", "))
  end
end
