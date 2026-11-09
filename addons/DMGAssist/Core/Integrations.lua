-- Integrations.lua: fitting into the player's own UI. Nothing here is required; each piece switches on by itself
-- when the other addon (or game feature) is there.
--   Masque       the icons are skinned with the player's Masque skin (group "DMGAssist"), like their action bars
--   Edit Mode    in Blizzard's Edit Mode the HUD shows, highlighted and draggable, with everything else
--   Data broker  a launcher for Titan Panel, ElvUI / ChocolateBar data texts and other LibDataBroker displays:
--                the target mode as text; left-click shows / hides, right-click settings, middle-click mode
--   Public API   the global DMGAssistAPI, for WeakAuras, UI packs and other addons (see the bottom of this file)
-- No library is shipped with DMGAssist: Masque and LibDataBroker are used only when another addon brought them.

local _, ns = ...
local U, L = ns.U, ns.L

local I = {}
ns.Integrations = I

---------------------------------------------------------------------------
-- Masque
---------------------------------------------------------------------------
local function Masque()
  local stub = _G.LibStub
  if type(stub) ~= "table" and type(stub) ~= "function" then
    return nil
  end
  local ok, lib = pcall(stub, "Masque", true)
  return ok and lib or nil
end

function I.MasqueActive()
  return I.group ~= nil
end

-- Called once the HUD frame exists.
function I.Skin(f)
  local lib = Masque()
  if not (lib and f) or I.group then
    return I.group ~= nil
  end
  local ok, group = pcall(lib.Group, lib, "DMGAssist", L["Recommendations"])
  if not (ok and group) then
    return false
  end
  I.group = group
  local icons = { f.slots[1], f.slots[2], f.slots[3], f.weave, f.trinket, f.kick, f.def, f.branch }
  for _, icon in ipairs(icons) do
    if icon and icon.tex then
      local added = pcall(group.AddButton, group, icon, { Icon = icon.tex, Normal = false, Pushed = false,
        Highlight = false, Cooldown = false }, "Legacy")
      if not added then
        pcall(group.AddButton, group, icon, { Icon = icon.tex })
      end
    end
  end
  U.Log("integration", "masque")
  return true
end

---------------------------------------------------------------------------
-- Which supported addons are here and in use (Status page, Integrations page, /dmga addons).
---------------------------------------------------------------------------
I.SUPPORTED = {
  { addon = "Masque", what = "icon skins", used = function() return I.MasqueActive() end },
  { addon = "Bartender4", what = "keybinds read from its bars" },
  { addon = "ElvUI", what = "keybinds from its bars, data text launcher" },
  { addon = "Dominos", what = "keybinds read from its bars" },
  { addon = "Titan", what = "launcher in Titan Panel", used = function() return I.broker ~= nil end },
  { addon = "DBM-Core", what = "boss mod warnings" },
  { addon = "BigWigs", what = "boss mod warnings" },
  { addon = "LittleWigs", what = "boss mod warnings" },
  { addon = "WeakAuras", what = "can read DMGAssist's picks (DMGAssistAPI)" },
}

local function Loaded(name)
  local f = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
  return f and U.Get(f, name) == true or false
end

-- { { addon, what, state = "in use" | "found" | "not installed" } }
function I.Detected()
  local out = {}
  for _, a in ipairs(I.SUPPORTED) do
    local state = "not installed"
    if Loaded(a.addon) then
      state = (a.used == nil or a.used()) and "in use" or "found"
    end
    out[#out + 1] = { addon = a.addon, what = a.what, state = state }
  end
  return out
end

-- "Masque, ElvUI, DBM-Core" (the ones in use), or nil
function I.InUse()
  local names = {}
  for _, d in ipairs(I.Detected()) do
    if d.state == "in use" then
      names[#names + 1] = d.addon
    end
  end
  return #names > 0 and table.concat(names, ", ") or nil
end

function I.PrintDetected()
  U.Print("%s", L["Addons DMGAssist works with:"])
  for _, d in ipairs(I.Detected()) do
    U.Print("  %s (%s): %s", d.addon, L[d.what], L[d.state])
  end
end

---------------------------------------------------------------------------
-- Blizzard Edit Mode
---------------------------------------------------------------------------
I.editMode = false

local function Overlay(f)
  if f.editOverlay then
    return f.editOverlay
  end
  local o = f:CreateTexture(nil, "OVERLAY")
  o:SetAllPoints(f)
  o:SetColorTexture(0.25, 0.6, 1, 0.3)
  local label = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  label:SetPoint("BOTTOM", f, "TOP", 0, 4)
  label:SetText(L["DMGAssist (drag to move)"])
  o.label = label
  f.editOverlay = o
  return o
end

function I.OnEditMode(on)
  I.editMode = on and true or false
  local D = ns.Display
  local f = D.frame
  if not f then
    return
  end
  local o = Overlay(f)
  o:SetShown(I.editMode)
  o.label:SetShown(I.editMode)
  if I.editMode then
    f:EnableMouse(true)
  else
    D.SetLocked(ns.db and ns.db.locked)
  end
  if ns.Update then
    ns.Update()
  end
end

function I.HookEditMode()
  local reg = _G.EventRegistry
  if I.editHooked or type(reg) ~= "table" or type(reg.RegisterCallback) ~= "function" then
    return false
  end
  I.editHooked = true
  pcall(reg.RegisterCallback, reg, "EditMode.Enter", function()
    I.OnEditMode(true)
  end, I)
  pcall(reg.RegisterCallback, reg, "EditMode.Exit", function()
    I.OnEditMode(false)
  end, I)
  return true
end

---------------------------------------------------------------------------
-- LibDataBroker (Titan Panel, ElvUI data texts, ChocolateBar, Bazooka, ...)
---------------------------------------------------------------------------
local ICON = "Interface\\Icons\\Spell_Holy_FistOfJustice"

function I.BrokerText()
  local text = ns.Display.ModeText and ns.Display.ModeText() or ""
  if ns.db and ns.db.enabled == false then
    return "|cff888888" .. L["off"] .. "|r"
  end
  return text ~= "" and text or "DMGAssist"
end

function I.HookBroker()
  if I.broker then
    return true
  end
  local stub = _G.LibStub
  if not stub then
    return false
  end
  local ok, ldb = pcall(stub, "LibDataBroker-1.1", true)
  if not (ok and ldb and ldb.NewDataObject) then
    return false
  end
  local made, obj = pcall(ldb.NewDataObject, ldb, "DMGAssist", {
    type = "data source",
    label = "DMGAssist",
    text = "DMGAssist",
    icon = ICON,
    OnClick = function(_, button)
      if button == "RightButton" then
        ns.Options.Open()
      elseif button == "MiddleButton" then
        DMGAssist_CycleMode()
      else
        DMGAssist_Toggle()
      end
    end,
    OnTooltipShow = function(tip)
      tip:AddLine("DMGAssist")
      tip:AddLine(I.BrokerText(), 1, 1, 1)
      tip:AddLine(L["Left-click: show / hide. Right-click: settings. Middle-click: target mode."], 0.8, 0.8, 0.8)
    end,
  })
  if not (made and obj) then
    return false
  end
  I.broker = obj
  C_Timer.NewTicker(1, function()
    local t = I.BrokerText()
    if obj.text ~= t then
      obj.text = t
    end
  end)
  U.Log("integration", "databroker")
  return true
end

---------------------------------------------------------------------------
-- Public API
---------------------------------------------------------------------------
-- DMGAssistAPI.GetRecommendation() -> nil, or a table:
--   { spells = { { spellID =, texture =, key =, source =, item = }, ... up to 3 },
--     interrupt = { spellID =, key = } or nil, defensive = { ... } or nil, offGCD = { ... } or nil, trinket = { ... } or nil,
--     mode = "AUTO" / "ST" / "AOE" }
-- DMGAssistAPI.RegisterCallback(fn) -> handle; fn(recommendation) runs whenever the pick changes.
-- DMGAssistAPI.UnregisterCallback(handle)
-- DMGAssistAPI.SetHUDHidden(true) hides DMGAssist's own icons while it keeps deciding (for a UI pack that draws
--   the recommendation itself). false shows them again. Not saved: call it on every login.
-- DMGAssistAPI.SetEnabled(bool), .CycleMode(), .ToggleCooldowns(), .OpenSettings(), .version

local API = {}
_G.DMGAssistAPI = API
I.callbacks = {}
I.hudHidden = false

local function Entry(p)
  if type(p) ~= "table" or p.sample then
    return nil -- nothing, or the settings preview's sample icons
  end
  local D = ns.Display
  local key = p.item and D.ItemKeybind and D.ItemKeybind(p.item) or (p.id and D.Keybind(p.id)) or nil
  local texture = p.texture or (p.id and U.Get(C_Spell and C_Spell.GetSpellTexture, p.id)) or nil
  return { spellID = p.id, item = p.item, texture = texture, key = key, source = p.source }
end

function I.Snapshot(result)
  if not (result and result.main) then
    return nil
  end
  local out = { spells = {} }
  for i, p in ipairs(result.queue or { result.main }) do
    if i > 3 then
      break
    end
    out.spells[#out.spells + 1] = Entry(p)
  end
  out.interrupt = Entry(result.interrupt)
  out.defensive = Entry(result.defensive)
  out.offGCD = Entry(result.weave)
  out.trinket = Entry(result.trinket)
  out.mode = ns.db and ns.db.autoDetect ~= false and "AUTO" or (ns.db and ns.db.mode == "st" and "ST" or "AOE")
  return out
end

local lastSig
function I.OnRecommendation(result)
  if not next(I.callbacks) then
    return
  end
  local q = result and result.queue or {}
  local function id(p)
    return p and (p.item or p.id) or "-"
  end
  local sig = table.concat({ tostring(id(q[1])), tostring(id(q[2])), tostring(id(q[3])),
    tostring(id(result and result.interrupt)), tostring(id(result and result.defensive)),
    tostring(id(result and result.weave)), tostring(id(result and result.trinket)) }, "/")
  if sig == lastSig then
    return
  end
  lastSig = sig
  local snap = I.Snapshot(result)
  for handle, fn in pairs(I.callbacks) do
    local ok, err = pcall(fn, snap)
    if not ok then
      I.callbacks[handle] = nil -- a broken callback is dropped, never breaks DMGAssist
      U.Log("api_callback_error", tostring(U.Safe(err)))
    end
  end
end

API.version = C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("DMGAssist", "Version") or "?"

API.L = ns.L -- DMGAssist's translations (the report window uses them too)

function API.GetRecommendation()
  return I.Snapshot(ns.last)
end

local nextHandle = 0
function API.RegisterCallback(fn)
  if type(fn) ~= "function" then
    return nil
  end
  nextHandle = nextHandle + 1
  I.callbacks[nextHandle] = fn
  lastSig = nil
  return nextHandle
end

function API.UnregisterCallback(handle)
  I.callbacks[handle] = nil
end

function API.SetHUDHidden(hidden)
  I.hudHidden = hidden and true or false
end

function API.SetEnabled(on)
  if (ns.db.enabled ~= false) ~= (on and true or false) then
    DMGAssist_Toggle()
  end
end

function API.CycleMode()
  DMGAssist_CycleMode()
end

function API.ToggleCooldowns()
  DMGAssist_ToggleBurst()
end

function API.OpenSettings()
  ns.Options.Open()
end

-- At login, once every addon has loaded.
function I.Setup()
  I.HookEditMode()
  I.HookBroker()
  I.Skin(ns.Display.frame)
end
