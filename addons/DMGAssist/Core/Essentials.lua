-- Essentials.lua: things a priority list does not cover but a player needs, put in slot 1 ahead of the rotation
-- (interrupts and defensives still come first).
--
-- Off-GCD keep-ups (Ironfur) never take slot 1: they are drawn as a small "weave" badge on slot 1's corner, one at
-- a time with at least a GCD between suggestions (a stack ending within a GCD plus reaction time counts as gone),
-- so stacks build while the rotation keeps generating Rage and
-- threat (front-loading three at the pull starved both, and slot 1 flipped between Ironfur and the rotation).
--
-- Keep-ups (tanks): SimC simulates damage, not survival or threat, so it spends Rage on Ironfur only in narrow
-- cases and never Moonfires a Guardian's target without Lunation. A keep-up is a per-spec rule:
--   stacks: keep N of our own stacking buff up (Ironfur: each cast is its own 7 s stack, counted from our casts,
--           since auras are hidden in combat). N is a setting, 0 = off.
--   dot:    keep our threat DoT on the target (Blizzard's own rule for Guardian: Moonfire if it isn't ticking).
-- Gap closers (melee): out of melee range of a hostile target, the spec's targeted charge / leap / step comes first
-- while it can reach; in range it is never shown. Directional dashes are left out (they need facing and aim).

local _, ns = ...
local U = ns.U

local X = {}
ns.Essentials = X

X.KEEPUPS = {
  -- Discipline: Atonement on allies, counted from our own casts (the game hides allies' buffs). Before a big hit
  -- a boss mod warns about, ramp: Radiance, then Shield, until the count reaches the target.
  priest_discipline = {
    { kind = "atonement", token = "power_word_radiance", id = 194509, setting = "atonementTarget",
      enabled = "atonementRamp", lead = "atonementLead",
      applies = { power_word_shield = 1, flash_heal = 1, plea = 1, shadow_mend = 1, renew = 1, void_shield = 1,
        power_word_radiance = 5 },
      duration = 15, radianceDuration = 9, extend = { evangelism = 6 },
      ramp = { "power_word_radiance", "power_word_shield", "void_shield" },
      -- Healing support (setting, groups only): keep this many Atonements up all the time, not only before a
      -- big hit: Shield while few are missing, Radiance when many are.
      keep = "atonementKeep", radianceAt = 3 },
  },
  -- Mistweaver, healing support in groups: Renewing Mist whenever a charge is ready (it jumps on its own and
  -- feeds the healing your damage does), so its charges never sit full.
  monk_mistweaver = {
    { kind = "group", token = "renewing_mist", id = 115151 },
  },
  -- Hunters: Hunter's Mark on a boss (SimC leaves it out: it's cast before the pull). Once per target.
  hunter_beast_mastery = { { kind = "mark", token = "hunters_mark", id = 257284 } },
  hunter_marksmanship = { { kind = "mark", token = "hunters_mark", id = 257284 } },
  hunter_survival = { { kind = "mark", token = "hunters_mark", id = 257284 } },
  druid_guardian = {
    { kind = "stacks", token = "ironfur", id = 192081, setting = "ironfurStacks", duration = 7 },
    { kind = "dot", token = "moonfire", id = 8921, cond = "!dot.moonfire.ticking" },
  },
}

-- Forms and stances: SimC's combat lists assume you are already in them (Moonkin Form is only in the precombat
-- list), so after a death, a dismount or a shapeshift the rotation would never ask for it. Blizzard's Assisted
-- Combat suggests the form exactly when you are out of it: that suggestion goes to slot 1.
X.FORMS = {
  [24858] = true,  -- Moonkin Form
  [768] = true,    -- Cat Form
  [5487] = true,   -- Bear Form
  [232698] = true, -- Shadowform
  [386164] = true, -- Battle Stance
  [386196] = true, -- Berserker Stance
  [386208] = true, -- Defensive Stance
}

function X.Form(result)
  local ac = result and result.acSpell
  if ac and X.FORMS[ac] and not ns.Choices.Skip(ac) and ns.Engine.Castable(ac) ~= false then
    return { id = ac, token = ns.SpellMap.TokenForID and ns.SpellMap.TokenForID(ac) or nil, source = "assisted",
      why = "form" }
  end
  return nil
end

-- Targeted gap closers, by spellbook ID (the form / talent override is what the game casts).
X.GAP_CLOSERS = {
  102401, -- Wild Charge (druid: Bear / Cat form versions)
  100,    -- Charge (warrior)
  36554,  -- Shadowstep (rogue)
  190925, -- Harpoon (survival hunter)
  196884, -- Feral Lunge (enhancement shaman)
  49576,  -- Death Grip (death knight: brings the target to you)
}

X.stacks = {} -- spell id -> { expiry, ... } from our own casts
X.lastWeave = {} -- spell id -> time of our last cast of it
X.WEAVE_GAP = 1.5 -- seconds between two suggestions of the same off-GCD keep-up
-- A stack counts as gone this long before it ends: the GCD you are in plus a human reaction, so the next cast
-- lands while the old one is still up (counting only the last 0.5 s, stacks kept dropping to one before the
-- refresh landed).
X.REACTION = 0.4
function X.StackLead()
  local gcd = tonumber((ns.State.GCD())) or 1.5
  return math.min(2.5, gcd + X.REACTION)
end
X.WEAVE_HOLD = 0.6 -- once shown, the badge stays while the spell flickers unusable for less than this

function X.OnOwnCast(id)
  if not id then
    return
  end
  local keep = X.KEEPUPS[ns.Specs.current and ns.Specs.current.key or ""]
  for _, k in ipairs(keep or {}) do
    if k.kind == "atonement" then
      local M = ns.SpellMap
      local token = M.TokenForID(M.baseOf[id] or id) or M.TokenForID(id)
      local list = X.stacks[k.id] or {}
      X.stacks[k.id] = list
      local n = token and k.applies[token]
      if n then
        local d = token == "power_word_radiance" and k.radianceDuration or k.duration
        for _ = 1, n do
          list[#list + 1] = GetTime() + d
        end
      elseif token and k.extend[token] then
        for i = 1, #list do
          list[i] = list[i] + k.extend[token]
        end
      end
    end
    if k.kind == "mark" and (id == k.id or ns.SpellMap.baseOf[id] == k.id) then
      X.NoteMarked()
    end
    if k.kind == "stacks" and (id == k.id or ns.SpellMap.baseOf[id] == k.id) then
      local info = ns.SpellMap.Info(k.id)
      local list = X.stacks[k.id] or {}
      X.stacks[k.id] = list
      list[#list + 1] = GetTime() + ((info and info.d and info.d > 0) and info.d or k.duration)
      X.lastWeave[k.id] = GetTime()
      X.shownWeave = nil
    end
  end
end

-- Our stacks that will still be up `lead` seconds from now.
function X.Stacks(id, lead)
  local list, n, now = X.stacks[id] or {}, 0, GetTime()
  for i = #list, 1, -1 do
    if list[i] <= now then
      table.remove(list, i)
    elseif list[i] > now + (lead or 0) then
      n = n + 1
    end
  end
  return n
end

-- At combat start: stacks are kept (an Ironfur cast just before the pull still counts; they expire on their own).
function X.Reset()
  X.lastWeave, X.shownWeave = {}, nil
  if X.LogStackSummary then
    X.LogStackSummary() -- the checks made since the last fight
  end
end

local function Known(id)
  local b = ns.SpellMap.book and ns.SpellMap.book[id]
  if b and not b.passive then
    return true
  end
  return U.Get(IsPlayerSpell, id) == true
end

local function Usable(id)
  if X.shownWeave and X.shownWeave.id == id and GetTime() - X.shownWeave.at < X.WEAVE_HOLD then
    return true -- steady badge: a brief unusable blink does not hide it
  end
  local usable = U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, id)))
  return usable == true and ns.State.CooldownReady(id) ~= false and not ns.Engine.IsHeld(id)
    and not ns.Choices.Skip(id) -- (hidden, or on none of your bars)
end

local function HostileTarget()
  return U.Get(UnitExists, "target") == true and U.Get(UnitCanAttack, "player", "target") == true
    and U.Get(UnitIsDead, "target") ~= true
end

-- Stack check: whenever the game lets us read our buffs (out of combat, or unrestricted), count the real stacks
-- of the counted keep-up, compare with our count, log the result for the Watchdog report, and correct our list.
-- Each Ironfur cast is its own aura instance, so instances are counted (applications when one instance stacks).
X.check = { match = 0, mismatch = 0, last = nil, at = 0 }

function X.RealStacks(id)
  local getter = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
  if type(getter) ~= "function" or U.Get(C_Secrets and C_Secrets.ShouldAurasBeSecret) == true then
    return nil
  end
  local n, expiries = 0, {}
  for i = 1, 80 do
    local aura = U.Call(getter, "player", i, "HELPFUL")
    if aura == nil then
      break
    end
    if U.IsSecret(aura) then
      return nil
    end
    local sid = U.Read(aura.spellId)
    if sid == nil then
      return nil
    end
    if sid == id then
      local apps = U.Read(aura.applications)
      apps = (type(apps) == "number" and apps > 0) and apps or 1
      local exp = U.Read(aura.expirationTime)
      for _ = 1, apps do
        n = n + 1
        expiries[#expiries + 1] = (type(exp) == "number" and exp > 0) and exp or (GetTime() + 7)
      end
    end
  end
  return n, expiries
end

-- The counted keep-up of the current spec ({ id, token, setting, ... }) when the player knows it, or nil.
function X.CountedKeepUp()
  local keep = X.KEEPUPS[ns.Specs.current and ns.Specs.current.key or ""]
  for _, k in ipairs(keep or {}) do
    if (k.kind == "stacks" or k.kind == "atonement") and Known(k.id) then
      return k
    end
  end
  return nil
end

function X.CheckStacks()
  local k = X.CountedKeepUp()
  if not k or k.kind ~= "stacks" or GetTime() - X.check.at < 1 then
    return -- (Atonement sits on allies: our own buffs say nothing about it)
  end
  X.check.at = GetTime()
  local real, expiries = X.RealStacks(k.id)
  if real == nil then
    return
  end
  local ours = X.Stacks(k.id)
  local sig = ours .. "/" .. real
  if ours == real then
    X.check.match = X.check.match + 1
  else
    X.check.mismatch = X.check.mismatch + 1
    if sig ~= X.check.last then
      U.Log("stack_check", { spell = k.token, ours = ours, real = real, combat = ns.State.combatStart ~= nil })
    end
    table.sort(expiries)
    X.stacks[k.id] = expiries -- the game's truth replaces our count
  end
  X.check.last = sig
end

function X.LogStackSummary()
  local c = X.check
  if c.match + c.mismatch > 0 then
    U.Log("stack_summary", { match = c.match, mismatch = c.mismatch })
  end
  X.check = { match = 0, mismatch = 0, last = nil, at = 0 }
end

-- The keep-up due now, or nil.
-- Discipline ramp: a big hit is coming (boss mod AoE timer within the lead) and fewer Atonements are counted than
-- the target: the first of Radiance / Shield that can be cast.
local function Ramp(k)
  if ns.db[k.enabled] == false then
    return nil
  end
  local want = tonumber(ns.db[k.setting]) or 5
  local lead = tonumber(ns.db[k.lead]) or 8
  local soon = ns.BossMods.Next("aoe")
  if not (soon and soon <= lead) or X.Stacks(k.id, soon) >= want then
    return nil
  end
  for _, token in ipairs(k.ramp) do
    local id = ns.SpellMap.SpellID(token)
    ns.SpellMap.unresolved[token] = nil
    if id and Usable(id) then
      return { id = id, token = token, source = "keepup", why = "ramp" }
    end
  end
  return nil
end
X.Ramp = Ramp

-- Healing support: in a group, with the setting on.
function X.InGroup()
  return (tonumber(U.Get(GetNumGroupMembers)) or 0) >= 2
end
local function HealSupport()
  return ns.db.healSupport == true and X.InGroup()
end
X.HealSupport = HealSupport

-- Discipline, healing support: the Atonement count kept up between big hits.
local function KeepAtonement(k)
  local want = math.min(tonumber(ns.db[k.keep]) or 3, tonumber(ns.db[k.setting]) or 5)
  local missing = want - X.Stacks(k.id, X.StackLead())
  if missing <= 0 then
    return nil
  end
  -- Shield first (one Atonement, cheap); Radiance only while several are missing and Shield can't be cast. Radiance
  -- first made it the only spell: its five Atonements end together, so three were always missing at once.
  local order = missing >= k.radianceAt and { "power_word_shield", "void_shield", "power_word_radiance" }
    or { "power_word_shield", "void_shield" }
  for _, token in ipairs(order) do
    local id = ns.SpellMap.SpellID(token)
    ns.SpellMap.unresolved[token] = nil
    if id and Usable(id) then
      return { id = id, token = token, source = "keepup", why = "atonement" }
    end
  end
  return nil
end
X.KeepAtonement = KeepAtonement

-- Hunter's Mark: which target carries ours. The aura is read when the game allows it; in combat, from our cast:
-- the target's GUID when readable, else "the target we had then" until the target changes.
X.marked = nil -- { guid = , at = } or { any = true }
local function TargetGUID()
  local g = U.Get(UnitGUID, "target")
  return type(g) == "string" and g or nil
end
function X.NoteMarked()
  local g = TargetGUID()
  X.marked = g and { guid = g, at = GetTime() } or { any = true, at = GetTime() }
end
function X.OnTargetChanged()
  if X.marked and X.marked.any then
    X.marked = nil
  end
end
-- true: our mark is on the target; false: it isn't; nil: unknown.
function X.TargetMarked(id)
  if ns.State.AurasReadable() and U.Get(C_Secrets and C_Secrets.ShouldAurasBeSecret) ~= true then
    local getter = C_UnitAuras and C_UnitAuras.GetAuraDataByIndex
    if type(getter) == "function" then
      for i = 1, 40 do
        local aura = U.Call(getter, "target", i, "HARMFUL")
        if aura == nil then
          -- not on it, unless we cast it this moment (the aura shows a little after the cast)
          local m, g = X.marked, TargetGUID()
          return m ~= nil and GetTime() - m.at < 2 and (m.any or g == m.guid)
        end
        local sid = not U.IsSecret(aura) and U.Read(aura.spellId)
        if sid == nil or sid == false then
          break -- unreadable after all: our own record decides
        end
        if sid == id then
          return true
        end
      end
    end
  end
  local m = X.marked
  if not m then
    return false
  end
  if m.any then
    return true
  end
  local g = TargetGUID()
  if g == nil then
    return nil
  end
  return g == m.guid
end

-- A boss: the game's boss flag, a world boss, or the skull level.
function X.TargetIsBoss()
  return U.Get(UnitIsBossMob, "target") == true or U.Get(UnitClassification, "target") == "worldboss"
    or U.Get(UnitLevel, "target") == -1
end

local function Mark(k)
  if ns.db.huntersMark == false or not HostileTarget() or not Known(k.id) or not X.TargetIsBoss() then
    return nil
  end
  if X.TargetMarked(k.id) ~= false or not Usable(k.id) then
    return nil
  end
  return { id = k.id, token = k.token, source = "keepup", why = "mark" }
end

function X.KeepUp()
  local keep = X.KEEPUPS[ns.Specs.current and ns.Specs.current.key or ""]
  if not keep then
    return nil
  end
  -- Hunter's Mark is also asked for before the pull, with a boss targeted.
  for _, k in ipairs(keep) do
    if k.kind == "mark" then
      local r = Mark(k)
      if r then
        return r
      end
    end
  end
  if not ns.State.combatStart then
    return nil
  end
  for _, k in ipairs(keep) do
    if k.kind == "atonement" then
      local r = Ramp(k) or (HealSupport() and KeepAtonement(k))
      if r then
        return r
      end
    elseif k.kind == "group" then
      local id = HealSupport() and (ns.SpellMap.SpellID(k.token) or (Known(k.id) and k.id))
      ns.SpellMap.unresolved[k.token] = nil
      if id and Usable(id) then
        return { id = id, token = k.token, source = "keepup", why = "support" }
      end
    elseif k.kind ~= "mark" and ns.db.tankEssentials ~= false and Known(k.id) and Usable(k.id) then
      if k.kind == "stacks" then
        local want = tonumber(ns.db[k.setting]) or 3
        local last = X.lastWeave[k.id]
        if want > 0 and X.Stacks(k.id, X.StackLead()) < want and not (last and GetTime() - last < X.WEAVE_GAP) then
          return { id = k.id, token = k.token, source = "keepup", weave = true }
        end
      elseif k.kind == "dot" and HostileTarget() then
        local S = ns.State
        local ok = ns.Expr.Test(k.cond, function(name)
          return S.Resolve(name, { vars = {} })
        end)
        if ok == true then
          return { id = k.id, token = k.token, source = "keepup" }
        end
      end
    end
  end
  return nil
end

-- Melee specs. The most common range among a spec's spells is no use here: Survival carries many 40 yd shots.
X.MELEE = {
  deathknight_blood = true, deathknight_frost = true, deathknight_unholy = true,
  demonhunter_havoc = true, demonhunter_vengeance = true, druid_feral = true, druid_guardian = true,
  hunter_survival = true, monk_brewmaster = true, monk_windwalker = true, paladin_protection = true,
  paladin_retribution = true, rogue_assassination = true, rogue_outlaw = true, rogue_subtlety = true,
  shaman_enhancement = true, warrior_arms = true, warrior_fury = true, warrior_protection = true,
}

-- The melee range check: the commonest melee-range (8 yd or less) spell the player knows; nil for ranged specs.
local meleeProbe = { book = false }
local function MeleeProbe()
  local key = ns.Specs.current and ns.Specs.current.key
  if not X.MELEE[key or ""] then
    return nil
  end
  local M = ns.SpellMap
  if meleeProbe.book == M.book and meleeProbe.key == key then
    return meleeProbe.id
  end
  local byRange, best, bestN = {}, nil, 0
  for id, b in pairs(M.book or {}) do
    local info = b.id == id and not b.passive and M.Info(id)
    if info and info.r and info.r > 0 and info.r <= 8 then
      local entry = byRange[info.r] or { n = 0, id = id }
      entry.n = entry.n + 1
      byRange[info.r] = entry
      if entry.n > bestN then
        best, bestN = entry.id, entry.n
      end
    end
  end
  meleeProbe.book, meleeProbe.key, meleeProbe.id = M.book, key, best
  return best
end
X.MeleeProbe = MeleeProbe

function X.GapCloser()
  if ns.db.gapClosers == false or not HostileTarget() then
    return nil
  end
  local probe = MeleeProbe()
  if not probe then
    return nil
  end
  local inMelee = U.Get(C_Spell and C_Spell.IsSpellInRange, probe, "target")
  if inMelee ~= false then
    return nil -- in range, or the game won't say
  end
  for _, id in ipairs(X.GAP_CLOSERS) do
    if Known(id) and Usable(id) and U.Get(C_Spell and C_Spell.IsSpellInRange, id, "target") == true then
      return { id = id, token = "gap_closer", source = "gapcloser" }
    end
  end
  return nil
end

local function Front(result, pick)
  local queue = { pick }
  for _, p in ipairs(result.queue or {}) do
    if p.id ~= pick.id and #queue < 3 then
      queue[#queue + 1] = p
    end
  end
  result.queue, result.main = queue, pick
  result.branch = nil
end

function X.Apply(result)
  if not result then
    return result
  end
  X.CheckStacks()
  local keep = X.KeepUp()
  result.weave = nil
  if keep and keep.weave then
    result.weave = keep
    local s = X.shownWeave
    if not (s and s.id == keep.id) then
      X.shownWeave = { id = keep.id, at = GetTime() }
    elseif U.Read((U.Call(C_Spell and C_Spell.IsSpellUsable, keep.id))) == true then
      s.at = GetTime()
    end
  elseif keep then
    X.shownWeave = nil
    Front(result, keep)
  else
    X.shownWeave = nil
  end
  local form = X.Form(result)
  if form then
    Front(result, form)
  end
  local gap = X.GapCloser()
  if gap then
    Front(result, gap)
  end
  return result
end
