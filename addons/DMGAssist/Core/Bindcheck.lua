-- Bindcheck.lua: spells (and on-use trinkets) DMGAssist can recommend that have no key binding.
--
-- Finding out mid-pull that the rotation wants a spell you never put on a key is annoying. This lists every spell
-- in the current spec's priority lists that you know, plus your interrupt, gap closer and enabled on-use trinkets,
-- whose action button has no key (or that is on no bar at all). Shown on the "Missing keybinds" settings page,
-- by /dmga unbound, and once per spec per session as a chat line (out of combat; can be switched off).

local _, ns = ...
local U, L = ns.U, ns.L

local B = {}
ns.Bindcheck = B

local function Name(id)
  return U.Get(C_Spell and C_Spell.GetSpellName, id) or ("spell " .. tostring(id))
end

local function OnBar(id)
  if ns.Display.ButtonFor(id) then
    return true
  end
  local slots = U.Get(C_ActionBar and C_ActionBar.FindSpellActionButtons, id)
  return type(slots) == "table" and #slots > 0
end

-- Every spell token in a record's priority lists.
local function Tokens(record, out)
  for _, field in ipairs({ "simc", "blizzard" }) do
    local lists = type(record) == "table" and record[field]
    if type(lists) == "table" then
      for _, list in pairs(lists) do
        if type(list) == "table" then
          for _, e in ipairs(list) do
            if type(e) == "table" and type(e.a) == "string" then
              out[e.a] = true
            end
          end
        end
      end
    end
  end
  return out
end

-- { { id =, item =, name =, texture =, onBar = bool }, ... } sorted by name.
function B.Missing()
  local state = ns.Specs.current
  local record = state and state.data
  local out, seen = {}, {}
  local M, G, D = ns.SpellMap, ns.Engine, ns.Display
  local function AddSpell(id)
    if not id or seen[id] then
      return
    end
    seen[id] = true
    if D.Keybind(id) or ns.Choices.IsHidden(id) then
      return
    end
    out[#out + 1] = { id = id, name = Name(id), texture = U.Get(C_Spell and C_Spell.GetSpellTexture, id),
      onBar = OnBar(id) }
  end
  if record then
    local unresolved = {}
    for k, v in pairs(M.unresolved or {}) do
      unresolved[k] = v
    end
    for token in pairs(Tokens(record, {})) do
      if not G.SKIP[token] then
        AddSpell(M.SpellID(token))
      end
    end
    M.unresolved = unresolved -- looking things up here is no sign of a missing spell in the rotation
  end
  if ns.db and ns.db.gapClosers ~= false and ns.Essentials.MeleeProbe() then
    for _, id in ipairs(ns.Essentials.GAP_CLOSERS) do
      local b = M.book and M.book[id]
      if b and not b.passive then
        AddSpell(b.id)
      end
    end
  end
  AddSpell(D.InterruptSpell and D.InterruptSpell())
  for _, info in ipairs(ns.Trinkets.List()) do
    if ns.Trinkets.Enabled(info) and not D.ItemKeybind(info.item) then
      out[#out + 1] = { item = info.item, id = info.spell, name = info.name or Name(info.spell),
        texture = info.texture, onBar = D.ItemOnBar(info.item), slot = info.slot }
    end
  end
  table.sort(out, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

function B.Describe(entry)
  local where = entry.onBar and L["on a bar, no key"] or L["not on your bars"]
  if entry.slot then
    where = L["trinket"] .. ", " .. where
  end
  return string.format("%s (%s)", tostring(entry.name), where)
end

function B.Print()
  ns.Display.InvalidateKeybinds()
  local list = B.Missing()
  if #list == 0 then
    U.Print("%s", L["Every spell DMGAssist can recommend has a key binding."])
    return list
  end
  U.Print(L["%d spells DMGAssist can recommend have no key binding:"], #list)
  for _, entry in ipairs(list) do
    U.Print("  %s", B.Describe(entry))
  end
  return list
end

-- Once per spec per session: a chat line if anything is unbound.
B.noticed = {}
B.NOTICE_DELAY = 8 -- seconds after login, so bar addons have set up their buttons

function B.MaybeNotice(inCombat)
  if inCombat or (ns.db and ns.db.bindWarn == false) then
    return
  end
  local state = ns.Specs.current
  local key = state and state.status == "ready" and state.key
  if not key or B.noticed[key] then
    return
  end
  B.readyAt = B.readyAt or (GetTime() + B.NOTICE_DELAY)
  if GetTime() < B.readyAt then
    return
  end
  B.noticed[key] = true
  local n = #B.Missing()
  if n > 0 then
    U.Print(L["%d spells in your rotation have no key binding. /dmga unbound lists them "
      .. "(also Settings > DMGAssist > Missing keybinds)."], n)
  end
end

-- Slot 1 shows a spell you have no key for (a hero talent's new button never put on a bar: Enhancement's Surging
-- Totem showed for a whole session as "a stick icon I can't find", 2026-11-10): say which spell it is, once per
-- spell per session, with its link.
B.shownWarned = {}
function B.OnShown(pick, small)
  if not (pick and pick.id) or pick.item or pick.sample or (ns.db and ns.db.bindWarn == false) then
    return
  end
  if B.shownWarned[pick.id] then
    return
  end
  local key = ns.Display.PickKeybind(pick)
  if key and key ~= "" then
    return
  end
  B.shownWarned[pick.id] = true
  local link = U.Get(C_Spell and C_Spell.GetSpellLink, pick.id) or Name(pick.id)
  if small then
    U.Print(L["%s is shown in a small icon (defensive or off-GCD) but has no key. Put it on a bar and give it a key, "
      .. "or hide it on the Spells & trinkets page."], tostring(link))
  elseif OnBar(pick.id) then
    U.Print(L["%s is in slot 1 but its button has no key. Bind one (Options > Keybindings) or press it from your bar."],
      tostring(link))
  else
    U.Print(L["%s is in slot 1 but isn't on your action bars. Drag it from the spellbook (hero talent spells are on "
      .. "a later page) onto a bar and give it a key, or hide it on the Spells & trinkets page."], tostring(link))
  end
end

