-- Leveling.lua: characters that don't have the spells a max-level priority list expects.
-- Slot 1 follows Blizzard's Assisted Combat while leveling; slots 2 and 3 come from the priority list (LV.Lead).
--
-- SimC's lists are written for a max-level character with a full talent build. A level 25 character knows a
-- handful of their spells, and an alt with talents picked at random may miss the ones the list leans on. Then
-- Blizzard's Assisted Combat leads instead: it is built for exactly that player and knows what they can cast.
-- Fully automatic ("Leveling" setting: Automatic / Always Blizzard / Always SimC):
--   below max level: Blizzard leads while you know less than LEAD_BELOW of the list's spells
--   at max level:    the priority list leads (a line needing a talent you skipped is passed over, and lines it
--                    can't judge are checked against Blizzard's assistant anyway); "Always Blizzard" is there for
--                    an alt whose talents are far from the usual build
--   starter specs (no specialization yet) always follow Blizzard (Specs.lua)
-- Interrupts, defensives, trinkets, buff reminders and your choices work the same either way.
--
-- Notices (out of combat, can be switched off):
--   a new spell DMGAssist can recommend, learned by leveling or a talent, that has no key: one chat line. Checked a
--   few seconds after learning it, because the game often puts a new spell on your bars itself (and if that slot
--   has a key, there is nothing to say)
--   unspent talent points after a level-up

local _, ns = ...
local U, L = ns.U, ns.L

local LV = {}
ns.Leveling = LV

LV.LEAD_BELOW = 0.6
LV.NOTICE_DELAY = 4 -- seconds after learning a spell, so the game can place it on a bar first
LV.MANY = 3 -- more new spells than this at once (a talent loadout change): one combined line

function LV.MaxLevel()
  return tonumber(U.Get(GetMaxLevelForPlayerExpansion)) or tonumber(U.Get(GetMaxPlayerLevel)) or nil
end

function LV.Level()
  return tonumber(U.Get(UnitLevel, "player"))
end

local function AssistantAvailable()
  return C_AssistedCombat ~= nil and C_AssistedCombat.GetNextCastSpell ~= nil
end

-- Decide whether Blizzard's assistant leads for this character. Sets state.leveling (and state.levelMatch).
function LV.Evaluate(state)
  if not state then
    return false
  end
  state.leveling = false
  if state.assistedOnly or not AssistantAvailable() or state.status ~= "ready" then
    return false
  end
  local mode = ns.db and ns.db.levelingMode or "auto"
  if mode == "simc" then
    return false
  end
  if mode == "blizzard" then
    state.leveling = true
    return true
  end
  local have, total = ns.ListMatch(state)
  if not (have and total and total >= 5) then
    return false
  end
  local share = have / total
  state.levelMatch = share
  local level, max = LV.Level(), LV.MaxLevel()
  state.leveling = (level and max and level < max and share < LV.LEAD_BELOW) and true or false
  return state.leveling
end

-- While leveling, Blizzard's Assisted Combat picks slot 1 (it knows what a low-level character should press);
-- the priority list, walked over the spells the character knows, fills slots 2 and 3. Without a suggestion from
-- Blizzard the list leads as usual.
function LV.Lead(result)
  local ac = result and result.acSpell
  if not ac or ns.Choices.IsHidden(ac) or (ns.Engine.held and ns.Engine.held[ac]) then
    return result
  end
  local pick = { id = ac, token = ns.SpellMap.TokenForID and ns.SpellMap.TokenForID(ac) or nil,
    source = "assisted", why = "leveling" }
  -- Blizzard's assistant also names a spell that is still on cooldown (the next important one, to wait for):
  -- then it goes to slot 2 and slot 1 keeps the best spell that can be pressed now.
  local ready = ns.Engine.Castable(ac) ~= false -- the engine's own check, the same as at max level
  local rest = {}
  for _, p in ipairs(result.queue or { result.main }) do
    if p and p.id ~= ac then
      rest[#rest + 1] = p
    end
  end
  local queue = {}
  -- A spell the engine only listed as "off cooldown soon" can't be pressed now either: it never takes slot 1.
  if ready or #rest == 0 or rest[1].source == "soon" then
    if not ready then
      -- Nothing else can be pressed now either: it stays in slot 1, marked "not yet" until its cooldown ends.
      local left = ns.State.CooldownRemains(ac)
      pick.readyAt = type(left) == "number" and left > 0 and GetTime() + left or nil
    end
    queue[1] = pick
  else
    queue[1] = rest[1]
    queue[2] = pick
    table.remove(rest, 1)
  end
  for _, p in ipairs(rest) do
    if #queue < 3 then
      queue[#queue + 1] = p
    end
  end
  result.queue, result.main, result.branch = queue, queue[1], nil
  return result
end

---------------------------------------------------------------------------
-- New spells without a key
---------------------------------------------------------------------------
LV.baseline = nil -- spell id -> true: what DMGAssist could show at the last check (nil: not set yet this session)
LV.baselineKey = nil
LV.told = {} -- spell id -> true: told once per session

local function Known()
  local out = {}
  for _, id in ipairs(ns.Choices.Spells()) do
    out[id] = true
  end
  return out
end

-- After every spell refresh (out of combat). The first one this session, or after a spec change, only sets the
-- baseline: switching spec or logging in is not learning anything.
function LV.OnSpellsChanged()
  local state = ns.Specs.current
  if not (state and state.status == "ready") then
    return
  end
  local now = Known()
  if not LV.baseline or LV.baselineKey ~= state.key then
    LV.baseline, LV.baselineKey = now, state.key
    return
  end
  local fresh = {}
  for id in pairs(now) do
    if not LV.baseline[id] and not LV.told[id] then
      fresh[#fresh + 1] = id
    end
  end
  LV.baseline = now
  if #fresh == 0 or (ns.db and ns.db.levelNotices == false) then
    return
  end
  table.sort(fresh)
  local key = state.key
  C_Timer.After(LV.NOTICE_DELAY, function()
    LV.TellNew(fresh, key)
  end)
end

function LV.TellNew(ids, key)
  local state = ns.Specs.current
  if not (state and state.key == key) then
    return
  end
  if ns.State.combatStart then
    LV.pending = ids -- after combat
    return
  end
  ns.Display.InvalidateKeybinds()
  local D = ns.Display
  local missing = {}
  for _, id in ipairs(ids) do
    LV.told[id] = true
    if not ns.Choices.IsHidden(id) and not D.Keybind(id) then
      missing[#missing + 1] = id
    end
  end
  if #missing == 0 then
    return -- the game put them on a bar with a key: nothing to say
  end
  if #missing > LV.MANY then
    U.Print(L["%d new spells have no key binding. Settings > DMGAssist > Missing keybinds lists them."], #missing)
    return
  end
  for _, id in ipairs(missing) do
    local name = ns.Choices.Name(id)
    local slots = U.Get(C_ActionBar and C_ActionBar.FindSpellActionButtons, id)
    if D.ButtonFor(id) or (type(slots) == "table" and #slots > 0) then
      U.Print(L["New spell: %s is on your bars but has no key. Give it one and DMGAssist will show it."], name)
    else
      U.Print(L["New spell: %s. Put it on your action bars with a key and DMGAssist will recommend it."], name)
    end
  end
end

function LV.OnCombatEnd()
  local ids = LV.pending
  LV.pending = nil
  if ids then
    LV.TellNew(ids, ns.Specs.current and ns.Specs.current.key)
  end
end

---------------------------------------------------------------------------
-- Unspent talent points
---------------------------------------------------------------------------
function LV.UnspentTalents()
  local CT = C_ClassTalents
  if CT and CT.HasUnspentTalentPoints then
    local v = U.Get(CT.HasUnspentTalentPoints)
    if v ~= nil then
      return v == true
    end
  end
  local configID = CT and U.Get(CT.GetActiveConfigID)
  local info = configID and C_Traits and U.Get(C_Traits.GetConfigInfo, configID)
  local trees = type(info) == "table" and info.treeIDs
  if type(trees) ~= "table" then
    return nil
  end
  for _, tree in ipairs(trees) do
    local currencies = U.Get(C_Traits.GetTreeCurrencyInfo, configID, tree, false)
    for _, c in ipairs(type(currencies) == "table" and currencies or {}) do
      if (tonumber(U.Read(c.quantity)) or 0) > 0 then
        return true
      end
    end
  end
  return false
end

function LV.OnLevelUp()
  if ns.db and ns.db.levelNotices == false then
    return
  end
  C_Timer.After(2, function()
    if ns.State.combatStart then
      return
    end
    if LV.UnspentTalents() then
      U.Print("%s", L["You have unspent talent points: press N to open your talents."])
    end
  end)
end
