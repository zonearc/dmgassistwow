-- Choices.lua: spells the player has switched off (Settings > DMGAssist > Spells & trinkets).
--
-- Per spec, by spell ID (the base spell, so a talent or form override of it is covered too): a hidden spell is
-- never shown, in any slot, as an interrupt, defensive, gap closer or keep-up. No priority changes: SimC's order
-- stays as it is, the next line simply takes its place. Kept in the profile, keyed by spell, so list updates
-- don't touch it; a hidden spell that leaves the rotation stays remembered and applies again if it comes back.
-- Trinkets are switched off per item (Trinkets.SetOff), on the same page.

local _, ns = ...
local U = ns.U

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

local function Store(create)
  local db = ns.db
  local key = C.SpecKey()
  if not (db and key) then
    return nil
  end
  if create then
    db.hidden = type(db.hidden) == "table" and db.hidden or {}
    db.hidden[key] = type(db.hidden[key]) == "table" and db.hidden[key] or {}
  end
  return type(db.hidden) == "table" and db.hidden[key] or nil
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
