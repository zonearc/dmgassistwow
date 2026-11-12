-- Choices.lua: spells the player has switched off (Settings > DMGAssist > Spells, trinkets & potion).
--
-- Per spec, by spell ID (the base spell, so a talent or form override of it is covered too): a hidden spell is
-- never shown, in any slot, as an interrupt, defensive, gap closer or keep-up. No priority changes: SimC's order
-- stays as it is, the next line simply takes its place. Kept in the profile, keyed by spell, so list updates
-- don't touch it; a hidden spell that leaves the rotation stays remembered and applies again if it comes back.
-- Trinkets are switched off per item (Trinkets.SetOff), on the same page.

local _, ns = ...
local U, L = ns.U, ns.L

local C = {}
ns.Choices = C

function C.SpecKey()
  local state = ns.Specs and ns.Specs.current
  return state and state.key or nil
end

local function Base(id)
  local M = ns.SpellMap
  return (M and M.baseOf and M.baseOf[id]) or id
end

local function Store(create, field)
  field = field or "hidden"
  local db = ns.db
  local key = C.SpecKey()
  if not (db and key) then
    return nil
  end
  if create then
    db[field] = type(db[field]) == "table" and db[field] or {}
    db[field][key] = type(db[field][key]) == "table" and db[field][key] or {}
  end
  return type(db[field]) == "table" and db[field][key] or nil
end

-- "First when ready": shown in slot 1 whenever it can be cast, ahead of the priority list (interrupts, defensives
-- and gap closers still come first). Per spec, by spell, like hiding.
function C.IsFirst(id)
  local t = id and Store(false, "first")
  return t ~= nil and (t[id] == true or t[Base(id)] == true)
end

function C.SetFirst(id, first)
  local t = Store(true, "first")
  if not (t and id) then
    return
  end
  local base = Base(id)
  t[base] = first and true or nil
  if base ~= id then
    t[id] = nil
  end
end

-- The spells marked "first" that the player knows, in a stable order (by spell ID).
function C.FirstSpells()
  local t = Store(false, "first")
  local out = {}
  for id, on in pairs(t or {}) do
    if on == true and not C.IsHidden(id) then
      local b = ns.SpellMap.book and ns.SpellMap.book[id]
      out[#out + 1] = (b and b.id) or id
    end
  end
  table.sort(out)
  return out
end

function C.IsHidden(id)
  if not id then
    return false
  end
  local t = Store(false)
  if not t then
    return false
  end
  return t[id] == true or t[Base(id)] == true
end

-- On one of your action bars (any bar addon that uses the game's action slots, or a macro casting it)? Forms
-- live on the stance bar and are exempt; with no buttons read at all (an unsupported bar addon) nothing is
-- filtered. Setting barsRequired (default on). Cached until the bars change.
local onBarsMemo, onBarsSerial = {}, nil
function C.OnBars(id)
  if not id or (ns.db and ns.db.barsRequired == false) then
    return true
  end
  local D = ns.Display
  if not (D and D.ButtonFor) or (ns.Essentials and ns.Essentials.FORMS and ns.Essentials.FORMS[id]) then
    return true
  end
  local serial = D.KeymapSerial and D.KeymapSerial() or 0
  if serial ~= onBarsSerial then
    onBarsMemo, onBarsSerial = {}, serial
  end
  local known = onBarsMemo[id]
  if known ~= nil then
    return known
  end
  local on = true
  if D.HasButtons and D.HasButtons() then
    on = D.ButtonFor(id) ~= nil
    if not on then
      for _, sid in ipairs({ id, Base(id) }) do
        local slots = U.Get(C_ActionBar and C_ActionBar.FindSpellActionButtons, sid)
        if type(slots) == "table" and #slots > 0 then
          on = true
          break
        end
      end
    end
  end
  onBarsMemo[id] = on
  return on
end

-- Not to be suggested at all: hidden by you, or on none of your bars (noted in chat once).
function C.Skip(id)
  if C.IsHidden(id) then
    return true
  end
  if not C.OnBars(id) then
    C.NoteOffBars(id)
    return true
  end
  return false
end

C.offBarsNoted = {}
-- For a moment after a spec / talent / spell-list change the old spec's lists run against the new bars: the
-- Assassination spells were named "not on your bars" right after switching to Outlaw, before "Spec changed"
-- (2026-11-11). Nothing is said (or marked as said) until things settle.
C.QUIET = 4
function C.QuietNotes()
  C.quietUntil = GetTime() + C.QUIET
end
function C.NotesQuiet()
  return C.quietUntil ~= nil and GetTime() < C.quietUntil
end

function C.NoteOffBars(id)
  local key = Base(id)
  if C.offBarsNoted[key] or (ns.db and ns.db.bindWarn == false) or C.NotesQuiet() then
    return
  end
  C.offBarsNoted[key] = true
  local link = U.Get(C_Spell and C_Spell.GetSpellLink, id) or C.Name(id)
  U.Print(L["%s is in your rotation but isn't on your action bars, so DMGAssist skips it. Drag it from the "
    .. "spellbook onto a bar (and give it a key) to have it suggested."], tostring(link))
end

function C.SetHidden(id, hidden)
  local t = Store(true)
  if not (t and id) then
    return
  end
  local base = Base(id)
  t[base] = hidden and true or nil
  if base ~= id then
    t[id] = nil
  end
end

-- DMGAssist switched off for one spec (an alt's healing spec you play without it): nothing is shown in that spec,
-- everything else stays as it is.
function C.SpecOff()
  local key = C.SpecKey()
  local t = ns.db and ns.db.specOff
  return key ~= nil and type(t) == "table" and t[key] == true
end

function C.SetSpecOff(off)
  local key = C.SpecKey()
  if not (ns.db and key) then
    return
  end
  ns.db.specOff = type(ns.db.specOff) == "table" and ns.db.specOff or {}
  ns.db.specOff[key] = off and true or nil
end

-- Every spell DMGAssist can show for this spec: the priority lists' spells the player knows, the gap closer, the
-- interrupt, the defensives and the keep-ups. Spell IDs, no duplicates.
function C.Spells()
  local state = ns.Specs.current
  local record = state and state.data
  local M, G = ns.SpellMap, ns.Engine
  local out, seen = {}, {}
  local function Add(id)
    if id and not seen[id] then
      seen[id] = true
      out[#out + 1] = id
    end
  end
  local unresolved = {}
  for k, v in pairs(M.unresolved or {}) do
    unresolved[k] = v
  end
  if type(record) == "table" then
    for _, field in ipairs({ "simc", "blizzard" }) do
      local lists = record[field]
      if type(lists) == "table" then
        for _, list in pairs(lists) do
          for _, e in ipairs(type(list) == "table" and list or {}) do
            if type(e) == "table" and type(e.a) == "string" and not G.SKIP[e.a] then
              Add(M.SpellID(e.a))
            end
          end
        end
      end
    end
  end
  if ns.Essentials.MeleeProbe() then
    for _, id in ipairs(ns.Essentials.GAP_CLOSERS) do
      local b = M.book and M.book[id]
      if b and not b.passive then
        Add(b.id)
      end
    end
  end
  for _, k in ipairs(ns.Essentials.KEEPUPS[state and state.key or ""] or {}) do
    local b = M.book and M.book[k.id]
    if b and not b.passive then
      Add(b.id)
    end
  end
  for _, id in ipairs(ns.Buffs and ns.Buffs.Spells() or {}) do
    Add(id)
  end
  Add(ns.Display.InterruptSpell and ns.Display.InterruptSpell(true))
  for _, token in ipairs(ns.Defensives.TOKENS or {}) do
    Add(M.SpellID(token))
  end
  M.unresolved = unresolved -- looking spells up here says nothing about the rotation
  return out
end

-- Last safety net after every module has had its say: nothing hidden is shown.
function C.Filter(result)
  if not (result and result.main) then
    return result
  end
  if result.weave and C.IsHidden(result.weave.id) and not result.weave.item then
    result.weave = nil
  end
  local queue = {}
  for _, p in ipairs(result.queue or { result.main }) do
    if p.item or not C.IsHidden(p.id) then
      queue[#queue + 1] = p
    end
  end
  result.queue = queue
  result.main = queue[1]
  return result
end

function C.Name(id)
  return U.Get(C_Spell and C_Spell.GetSpellName, id) or ("spell " .. tostring(id))
end
