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
  if state.source then
    parts[#parts + 1] = string.format("SimC %s %s (%s)", tostring(state.source.branch), tostring(state.source.commit),
      tostring(state.source.date))
  end
  return table.concat(parts, " | ")
end
ns.Describe = Describe

---------------------------------------------------------------------------
-- Spell map refresh: out of combat only (spellbook and talents can't change in combat)
---------------------------------------------------------------------------
local spellsDirty = true
local inCombat = false

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

Specs.OnChange(function(state, previous)
  M.SetData(state.data)
  if state.key then
    S.Bind(state.key)
  end
  RefreshSpells()
  if previous then
    U.Print(L["Spec changed: %s"], Describe(state))
  end
end)

---------------------------------------------------------------------------
-- The loop
---------------------------------------------------------------------------
ns.last = nil
local lastLogged

local function ShouldShow()
  if not (ns.db and ns.db.enabled ~= false) then
    return false
  end
  local enemy = U.Read(U.Call(UnitExists, "target")) == true and
    U.Read(U.Call(UnitCanAttack, "player", "target")) == true
  return D.ShouldShow(inCombat, enemy)
end

function ns.Update()
  local state = Specs.current
  if not state or state.status ~= "ready" or not state.data then
    D.Update(nil, false)
    return nil
  end
  if spellsDirty and not inCombat then
    RefreshSpells()
  end
  D.MaybeRefreshKeymap(inCombat)
  ns.Diagnostics.Tick()
  local show = ShouldShow()
  if not show then
    D.Update(nil, false)
    return nil
  end
  S.VerifyPowers()
  ns.Clues.ReadCooldownManager(S.ReadableAuras())
  local result = G.Recommend(state.data, {
    burst = ns.db.burst ~= false,
    useAssisted = state.branch == "midnight" and ns.db.useAssisted ~= false,
  })
  result.callout = ns.BossMods.Callout()
  ns.Interrupts.Apply(result)
  ns.Diagnostics.OnPick(result)
  ns.last = result
  D.Update(result, true)
  -- Decision log: one line per change of pick (not every tick).
  local main, cd = result.main, result.cd
  local q2, q3 = result.queue and result.queue[2], result.queue and result.queue[3]
  local sig = (main and (main.token or main.id) or "-") .. "/" .. (cd and cd.token or "-") .. "/" ..
    tostring(result.modeLabel)
  if sig ~= lastLogged then
    lastLogged = sig
    U.Log("pick", {
      main = main and main.token, source = main and main.source, cd = cd and cd.token, ac = result.acSpell,
      next = q2 and q2.token, after = q3 and q3.token, mode = result.modeLabel,
    })
  end
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
  "PLAYER_REGEN_ENABLED", "PLAYER_TARGET_CHANGED", "SPELL_UPDATE_COOLDOWN", "SPELL_ACTIVATION_OVERLAY_GLOW_SHOW",
  "SPELL_ACTIVATION_OVERLAY_GLOW_HIDE" }) do
  frame:RegisterEvent(event)
end
-- Keybind text on the icons follows action bar and binding changes.
local KEYBIND_EVENTS = { ACTIONBAR_SLOT_CHANGED = true, UPDATE_BINDINGS = true, ACTIONBAR_PAGE_CHANGED = true,
  UPDATE_BONUS_ACTIONBAR = true, UPDATE_MACROS = true, UPDATE_SHAPESHIFT_FORM = true }
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
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_START", "target")
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELLCAST_CHANNEL_START", "target")
pcall(frame.RegisterUnitEvent, frame, "UNIT_SPELL_HASTE", "player")
for _, event in ipairs({ "SPELL_UPDATE_USABLE", "SPELL_UPDATE_ICON", "COOLDOWN_VIEWER_SPELL_OVERRIDE_UPDATED",
  "ENCOUNTER_START", "ENCOUNTER_END" }) do
  pcall(frame.RegisterEvent, frame, event)
end
pcall(frame.RegisterUnitEvent, frame, "UNIT_AURA", "player", "target")

local DEFAULTS = { enabled = true, burst = true, mode = "st", autoDetect = true, aoeTargets = 3, fightLength = 300,
  useAssisted = true, queue = 3, smartFight = true, bossMods = true, interruptMode = "smart" }

frame:SetScript("OnEvent", function(_, event, ...)
  local arg1, _, arg3 = ...
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      DMGAssistDB = type(DMGAssistDB) == "table" and DMGAssistDB or {}
      for k, v in pairs(DEFAULTS) do
        if DMGAssistDB[k] == nil then
          DMGAssistDB[k] = v
        end
      end
      ns.db = DMGAssistDB
      ns.Client.Detect()
    end
    ns.BossMods.Hook() -- boss mods can load before us, after us, or on demand
    D.InvalidateKeybinds() -- a bar addon may have just loaded
  elseif event == "PLAYER_LOGIN" then
    local state = Specs.Refresh("login")
    U.Print("%s", Describe(state))
    local loaded = ns.Data.LoadedBranches()
    if #loaded > 1 then
      U.Print(L["Warning: data for %s loaded at once; using %s."], table.concat(loaded, " and "), tostring(state.branch))
      U.Log("data_gating", table.concat(loaded, ","))
    end
    D.Create()
    ns.Options.Register()
    ns.BossMods.Hook()
  elseif KEYBIND_EVENTS[event] then
    D.InvalidateKeybinds()
  elseif event == "PLAYER_REGEN_DISABLED" then
    inCombat = true
    S.OnCombat(true)
    ns.Diagnostics.OnCombat(true)
  elseif event == "PLAYER_REGEN_ENABLED" then
    inCombat = false
    S.OnCombat(false)
    ns.Diagnostics.OnCombat(false)
    S.Calibrate()
    if spellsDirty then
      RequestSpellRefresh()
    end
  elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
    if arg1 == "player" then
      S.OnSpellcastSucceeded(arg3)
    end
  elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
    ns.Interrupts.OnTargetCastStart()
  elseif event == "UNIT_POWER_UPDATE" then
    ns.Clues.OnPowerEvent(U.Read(select(2, ...)))
  elseif event == "UNIT_SPELL_HASTE" then
    S.OnHasteChanged()
  elseif event == "SPELL_UPDATE_USABLE" then
    ns.Clues.ScanRequirements(S.AurasReadable())
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
  elseif event == "PLAYER_TARGET_CHANGED" then
    S.OnTargetChanged()
    ns.Interrupts.OnTargetCastStart()
  else
    Specs.RequestRefresh(event)
    if SPELL_EVENTS[event] then
      RequestSpellRefresh()
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
  end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local commands = {}

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
  end
  U.Print(L["AoE targets: %d."], ns.db.aoeTargets)
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

function commands.keys()
  local map = D.BuildKeymap()
  local n = 0
  for _ in pairs(map) do
    n = n + 1
  end
  U.Print(L["Keybinds refreshed: %d spells on your bars."], n)
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
  U.Print(L["Next: %s (%s). Cooldown slot: %s. Assisted Combat says: %s."], table.concat(names, " > "),
    tostring(r.main.source), tostring(r.cd and r.cd.token or "-"), tostring(r.acSpell or "-"))
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
  local mods = ns.BossMods.Detected()
  if #mods > 0 then
    U.Print(L["Boss mods: %s."], table.concat(mods, ", "))
  end
end
