-- Specs.lua: who is the player right now, and which priority data applies?
--
-- Spec IDs are copied from Blizzard's own table in Blizzard_ClassSpecializationsFrame.lua, identical on the
-- `live` and `forever` branches of the UI source (2026-11-07). Keys are SimC file names, except where SimC
-- spells a spec differently from Blizzard (hunter-beastmastery -> hunter_beast_mastery).
--
-- Spec changes happen without a /reload, so Refresh() runs on every relevant event; several of those events
-- fire together, so refreshes are coalesced into one, a fraction of a second later.

local _, ns = ...
local U = ns.U

local S = {}
ns.Specs = S

S.KEYS = {
  [62] = "mage_arcane", [63] = "mage_fire", [64] = "mage_frost",
  [65] = "paladin_holy", [66] = "paladin_protection", [70] = "paladin_retribution",
  [71] = "warrior_arms", [72] = "warrior_fury", [73] = "warrior_protection",
  [102] = "druid_balance", [103] = "druid_feral", [104] = "druid_guardian", [105] = "druid_restoration",
  [250] = "deathknight_blood", [251] = "deathknight_frost", [252] = "deathknight_unholy",
  [253] = "hunter_beast_mastery", [254] = "hunter_marksmanship", [255] = "hunter_survival",
  [256] = "priest_discipline", [257] = "priest_holy", [258] = "priest_shadow",
  [259] = "rogue_assassination", [260] = "rogue_outlaw", [261] = "rogue_subtlety",
  [262] = "shaman_elemental", [263] = "shaman_enhancement", [264] = "shaman_restoration",
  [265] = "warlock_affliction", [266] = "warlock_demonology", [267] = "warlock_destruction",
  [268] = "monk_brewmaster", [269] = "monk_windwalker", [270] = "monk_mistweaver",
  [577] = "demonhunter_havoc", [581] = "demonhunter_vengeance", [1480] = "demonhunter_devourer",
  [1467] = "evoker_devastation", [1468] = "evoker_preservation", [1473] = "evoker_augmentation",
}

-- Events after which the spec, talents or known spells may have changed.
S.EVENTS = {
  "PLAYER_SPECIALIZATION_CHANGED",       -- unit
  "ACTIVE_PLAYER_SPECIALIZATION_CHANGED",
  "ACTIVE_TALENT_GROUP_CHANGED",
  "PLAYER_TALENT_UPDATE",
  "TRAIT_CONFIG_UPDATED",                -- talent loadout edits
  "ACTIVE_COMBAT_CONFIG_CHANGED",        -- Forever: talent tree config switched (used by WoWSims' exporter too)
  "SPELLS_CHANGED",
  "PLAYER_LEVEL_UP",
}

S.current = nil
local listeners = {}
local pending = false
local REFRESH_DELAY = 0.2

function S.OnChange(fn)
  listeners[#listeners + 1] = fn
end

local function SpecIndex()
  local r = U.Try(C_SpecializationInfo and C_SpecializationInfo.GetSpecialization)
  if not r.ok then
    r = U.Try(GetSpecialization)
  end
  if r.ok and type(r[1]) == "number" and r[1] > 0 then
    return r[1]
  end
  return nil
end

local function SpecInfo(index)
  local r = U.Try(C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfo, index)
  if not r.ok then
    r = U.Try(GetSpecializationInfo, index)
  end
  if r.ok then
    return r[1], r[2], r[5] -- specID, localized name, role
  end
end

-- Work out the current spec and data. Returns the state table (also stored in S.current).
function S.Detect()
  local client = ns.Client.info or ns.Client.Detect()
  local state = { branch = client.branch, client = client.name }
  local c = U.Try(UnitClass, "player")
  if c.ok then
    state.class = c[2]
  end
  local index = SpecIndex()
  state.specIndex = index
  if index then
    state.specID, state.specName, state.role = SpecInfo(index)
  end
  local key = type(state.specID) == "number" and S.KEYS[state.specID] or nil
  state.key = key
  if not client.branch then
    state.status = "unsupported_client"
  elseif (not index or not key) and C_AssistedCombat and C_AssistedCombat.GetNextCastSpell and state.class then
    -- A new character's starter spec (or none chosen yet): no SimC list exists for it, but Blizzard's assistant
    -- knows exactly what a level 5 character can cast, so slot 1 follows it.
    state.key = string.lower(state.class) .. "_starter"
    state.data = { key = state.key, simc = { default = {} }, simcOrder = { "default" }, assistedOnly = true }
    state.status = "ready"
    state.assistedOnly = true
    state.starter = true
  elseif not index then
    state.status = "no_spec"            -- low-level characters before choosing a specialization
  elseif not key then
    state.status = "unknown_spec"       -- a spec ID we have never seen: report it
  else
    state.data = ns.Data.Get(client.branch, key)
    state.source = ns.Data.Source(client.branch)
    if state.data then
      state.status = "ready"
    elseif ns.Data.Source(client.branch) and (client.branch == "midnight"
      or (C_AssistedCombat and C_AssistedCombat.GetNextCastSpell)) then
      -- No SimC list (healers: Discipline, Holy, Mistweaver, Preservation, Restoration Shaman / Holy Paladin):
      -- Blizzard's Assisted Combat still suggests their damage rotation, so slot 1 follows it (with interrupts,
      -- defensives, trinkets and your choices) instead of hiding the HUD.
      state.data = { key = key, simc = { default = {} }, simcOrder = { "default" }, assistedOnly = true }
      state.status = "ready"
      state.assistedOnly = true
    elseif ns.Data.Source(client.branch) then
      state.status = "no_simc_list"     -- e.g. healer specs: SimC publishes no default list
    else
      state.status = "data_not_loaded"  -- the .toc gating did not load this client's data
    end
  end
  return state
end

local function Same(a, b)
  return a and b and a.key == b.key and a.status == b.status and a.specID == b.specID and a.branch == b.branch
end

function S.Refresh(reason)
  local state = S.Detect()
  state.reason = reason
  local previous = S.current
  S.current = state
  if not Same(previous, state) then
    U.Log("spec", (state.key or "none") .. ":" .. state.status)
    for _, fn in ipairs(listeners) do
      local ok, err = pcall(fn, state, previous)
      if not ok then
        U.Print("spec listener error: %s", tostring(U.Safe(err)))
      end
    end
  end
  return state
end

-- Coalesce bursts of events into one refresh.
function S.RequestRefresh(reason)
  if pending then
    return
  end
  if not (C_Timer and C_Timer.After) then
    S.Refresh(reason)
    return
  end
  pending = true
  C_Timer.After(REFRESH_DELAY, function()
    pending = false
    S.Refresh(reason)
  end)
end
