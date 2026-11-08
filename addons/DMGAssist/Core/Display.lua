-- Display.lua: the HUD.
--
--   ┌ DMGAssist · Feral · AUTO 3 ─────────────── ⚙ ┐   header (optional): spec, target mode, settings button
--   │ [ NOW ]  [ NEXT ] [ NEXT ]                     │   main icon + queue (1-3), keybind text, spell names
--   │ ▓▓▓▓▓▓▓░░░ GCD                                 │   GCD bar under the main icon
--   │ [ CD ]                                         │   major cooldown (burst toggle)
--   └────────────────────────────────────────────────┘
--
-- Every element and size is a setting (ns.db.hud, see D.DEFAULTS; edited in Options > AddOns > DMGAssist).
-- Left-drag moves it while unlocked; right-click cycles the target mode; the gear opens the settings.
-- Rebuilt in place when a setting changes (D.Rebuild).

local _, ns = ...
local U, L = ns.U, ns.L

local D = {}
ns.Display = D

D.DEFAULTS = {
  scale = 1.0, alpha = 1.0,
  iconSize = 52, nextSize = 38, cdSize = 34, spacing = 6, padding = 6,
  queueAlpha = 0.85, dimGuesses = true,
  background = true, bgAlpha = 0.55, border = "thin", borderAlpha = 0.6,
  header = true, keybind = true, keybindSize = 14, keybindPos = "TOPRIGHT",
  spellNames = false, nameSize = 10, labels = false,
  gcdBar = true, glow = "pulse",
  hideOutOfCombat = true, showWithTarget = true,
  debugText = false, callout = true, pressCue = true,
}

local GOLD = { 1, 0.69, 0 }
local SOURCE_TEXT = {
  simc = "", ["simc+assisted"] = "", ["simc+rules"] = "",
  assisted = "AC", rules = "B", ["rules?"] = "?", guess = "?",
}
local FONT = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"

function D.Settings()
  local db = ns.db or {}
  if type(db.hud) ~= "table" then
    db.hud = {}
  end
  for k, v in pairs(D.DEFAULTS) do
    if db.hud[k] == nil then
      db.hud[k] = v
    end
  end
  return db.hud
end

---------------------------------------------------------------------------
-- Keybinds: which key casts this spell? (action bar slot -> binding command -> key)
-- Pages: 1 and 7-12 (forms/bonus bars) = main bar ACTIONBUTTON; 6/5/3/4/13/14/15 = MULTIACTIONBAR1..7
-- (Blizzard_ActionBar/Shared/MultiActionBars.xml actionpage attributes).
---------------------------------------------------------------------------
local PAGE_COMMAND = { [6] = "MULTIACTIONBAR1BUTTON", [5] = "MULTIACTIONBAR2BUTTON", [3] = "MULTIACTIONBAR3BUTTON",
  [4] = "MULTIACTIONBAR4BUTTON", [13] = "MULTIACTIONBAR5BUTTON", [14] = "MULTIACTIONBAR6BUTTON",
  [15] = "MULTIACTIONBAR7BUTTON" }
local keyCache = {}
local keymap, keymapAt = nil, 0

function D.InvalidateKeybinds()
  keyCache = {}
  keymap = nil
end

local function Shorten(text)
  text = text:gsub("SHIFT%-", "S"):gsub("CTRL%-", "C"):gsub("ALT%-", "A")
  text = text:gsub("Mouse Button ", "M"):gsub("Middle Mouse", "M3"):gsub("Num Pad ", "N")
  return text
end

local function BindingFor(slot, mainPage)
  local page = math.floor((slot - 1) / 12) + 1
  local index = (slot - 1) % 12 + 1
  local command
  if page == mainPage or page == 1 or (page >= 7 and page <= 12) then
    command = "ACTIONBUTTON" .. index
  elseif PAGE_COMMAND[page] then
    command = PAGE_COMMAND[page] .. index
  end
  if not command then
    return nil, false
  end
  local key = U.Read(U.Call(GetBindingKey, command))
  if type(key) ~= "string" then
    return nil, false
  end
  local text = U.Read(U.Call(GetBindingText, key, 1))
  return Shorten(type(text) == "string" and text or key), page == mainPage
end

-- Action bar addons bind keys to their own buttons ("CLICK <button>:LeftButton"); the button's action slot is an
-- attribute. Patterns for the common ones (LibActionButton-based Bartender4/ElvUI, and Dominos).
local ADDON_BUTTONS = {
  { pattern = "BT4Button%d", count = 180 },
  { pattern = "DominosActionButton%d", count = 180 },
}
for bar = 1, 15 do
  ADDON_BUTTONS[#ADDON_BUTTONS + 1] = { pattern = "ElvUI_Bar" .. bar .. "Button%d", count = 12 }
end

local function MainPage()
  local bonus = U.Read(U.Call(C_ActionBar and C_ActionBar.GetBonusBarOffset))
  if type(bonus) == "number" and bonus > 0 then
    return 6 + bonus
  end
  return U.Read(U.Call(C_ActionBar and C_ActionBar.GetActionBarPage)) or 1
end

-- What spell an action slot casts: a spell, or the spell a macro currently shows.
local function SlotSpell(slot)
  local kind, id = U.Call(GetActionInfo, slot)
  kind, id = U.Read(kind), U.Read(id)
  if kind == "spell" and type(id) == "number" then
    return id
  elseif kind == "macro" and id then
    local a, b, c = U.Call(GetMacroSpell, id)
    a, b, c = U.Read(a), U.Read(b), U.Read(c)
    for _, v in ipairs({ a, b, c }) do
      if type(v) == "number" then
        return v
      end
    end
  end
  return nil
end

D.KEYMAP_REFRESH = 10 -- seconds, out of combat

-- Build spellID -> key text for every bar: Blizzard bars (pages), macros on them, and bar addons' buttons.
function D.BuildKeymap()
  local map, onMain = {}, {}
  local mainPage = MainPage()
  local function Put(spellID, text, main)
    if spellID and text and (not map[spellID] or (main and not onMain[spellID])) then
      map[spellID], onMain[spellID] = text, main
    end
  end
  for slot = 1, 180 do
    local sid = SlotSpell(slot)
    if sid then
      local text, main = BindingFor(slot, mainPage)
      Put(sid, text, main)
    end
  end
  for _, def in ipairs(ADDON_BUTTONS) do
    for i = 1, def.count do
      local name = def.pattern:format(i)
      local button = _G[name]
      if type(button) == "table" then
        local slot = U.Read(button._state_action) or U.Read(button.action)
        if not slot and button.GetAttribute then
          slot = U.Read(U.Call(button.GetAttribute, button, "action"))
        end
        slot = tonumber(slot)
        local key = U.Read(U.Call(GetBindingKey, "CLICK " .. name .. ":LeftButton"))
          or U.Read(U.Call(GetBindingKey, "CLICK " .. name .. ":Keybind"))
        if slot and type(key) == "string" then
          local text = U.Read(U.Call(GetBindingText, key, 1))
          Put(SlotSpell(slot), Shorten(type(text) == "string" and text or key), false)
        end
      end
    end
  end
  keymap, keymapAt = map, GetTime()
  keyCache = {}
  return map
end

function D.Keybind(spellID)
  if not spellID then
    return nil
  end
  local cached = keyCache[spellID]
  if cached ~= nil then
    return cached or nil
  end
  if not keymap then
    D.BuildKeymap()
  end
  local best = keymap[spellID]
  local base = ns.SpellMap and ns.SpellMap.baseOf[spellID]
  if not best and base then
    best = keymap[base]
  end
  if not best then
    -- Slots the game knows hold this spell (covers overrides and flyouts).
    local slots = U.Read(U.Call(C_ActionBar and C_ActionBar.FindSpellActionButtons, spellID))
    if type(slots) == "table" then
      local mainPage = MainPage()
      for _, slot in ipairs(slots) do
        local text, main = BindingFor(slot, mainPage)
        if text and (main or not best) then
          best = text
          if main then
            break
          end
        end
      end
    end
  end
  keyCache[spellID] = best or false
  return best
end

-- Out of combat, rebuild now and then even without an event (bar addons sometimes change bindings silently).
function D.MaybeRefreshKeymap(inCombat)
  if not inCombat and GetTime() - keymapAt > D.KEYMAP_REFRESH then
    D.BuildKeymap()
  end
end

---------------------------------------------------------------------------
-- Building
---------------------------------------------------------------------------
local function SetFont(fs, size)
  fs:SetFont(FONT, size, "OUTLINE")
end

local function Icon(parent, size, cfg)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size, size)
  f.tex = f:CreateTexture(nil, "ARTWORK")
  f.tex:SetAllPoints(f)
  f.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  f.source = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.source, math.max(9, math.floor(size / 4)))
  f.source:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  f.key = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.key, cfg.keybindSize)
  f.key:SetPoint(cfg.keybindPos, f, cfg.keybindPos, cfg.keybindPos:find("LEFT") and 2 or -2,
    cfg.keybindPos:find("TOP") and -2 or 2)
  f.name = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.name, cfg.nameSize)
  f.name:SetPoint("TOP", f, "BOTTOM", 0, -2)
  f.name:SetWidth(size + 24)
  f.label = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.label, 9)
  f.label:SetPoint("BOTTOM", f, "TOP", 0, 1)
  f:Hide()
  return f
end

local function Glow(icon)
  local g = icon:CreateTexture(nil, "OVERLAY")
  g:SetPoint("TOPLEFT", icon, "TOPLEFT", -3, 3)
  g:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 3, -3)
  g:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.35)
  g:SetDrawLayer("BACKGROUND")
  return g
end

local function ApplyBackdrop(f, cfg)
  if not f.SetBackdrop then
    return
  end
  if not cfg.background and cfg.border == "none" then
    f:SetBackdrop(nil)
    return
  end
  local edge = (cfg.border == "thick" and 2) or 1
  f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = edge })
  f:SetBackdropColor(0.05, 0.05, 0.08, cfg.background and cfg.bgAlpha or 0)
  f:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], cfg.border == "none" and 0 or cfg.borderAlpha)
end

local function Layout(f, cfg)
  local pad, gap = cfg.padding, cfg.spacing
  local top = pad
  if cfg.header then
    f.header:Show()
    f.gear:Show()
    top = top + 16
  else
    f.header:Hide()
    f.gear:Hide()
  end
  local depth = (ns.db and tonumber(ns.db.queue)) or 3
  local x = pad
  for i = 1, 3 do
    local s = f.slots[i]
    s:ClearAllPoints()
    local size = i == 1 and cfg.iconSize or cfg.nextSize
    s:SetSize(size, size)
    s:SetPoint("TOPLEFT", f, "TOPLEFT", x, -top - (i == 1 and 0 or (cfg.iconSize - cfg.nextSize)))
    if i <= depth then
      x = x + size + gap
    end
  end
  local width = math.max(x - gap + pad, 120)
  local y = top + cfg.iconSize + (cfg.spellNames and (cfg.nameSize + 4) or 0)
  f.gcd:ClearAllPoints()
  if cfg.gcdBar then
    f.gcd:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -(y + 3))
    f.gcd:SetSize(cfg.iconSize, 4)
    f.gcdBg:SetAllPoints(f.gcd)
    y = y + 8
  end
  f.cd:ClearAllPoints()
  f.cd:SetSize(cfg.cdSize, cfg.cdSize)
  f.cd:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -(y + gap))
  y = y + gap + cfg.cdSize
  f.debug:ClearAllPoints()
  f.debug:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -(y + 2))
  f.debug:SetWidth(width - 2 * pad)
  if cfg.debugText then
    y = y + 26
  end
  f:SetSize(width, y + pad)
end

function D.Create()
  if D.frame then
    return D.frame
  end
  local cfg = D.Settings()
  local db = ns.db or {}
  local f = CreateFrame("Frame", "DMGAssistDisplay", UIParent, "BackdropTemplate")
  local pos = type(db.point) == "table" and db.point or nil
  if pos then
    f:SetPoint(pos[1] or "CENTER", UIParent, pos[2] or "CENTER", tonumber(pos[3]) or 0, tonumber(pos[4]) or -150)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
  end
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    if not (ns.db and ns.db.locked) then
      self:StartMoving()
    end
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p1, _, p2, x, y = self:GetPoint()
    if ns.db then
      ns.db.point = { p1, p2, x, y }
    end
  end)
  f:SetScript("OnMouseUp", function(_, button)
    if button == "RightButton" and DMGAssist_CycleMode then
      DMGAssist_CycleMode()
    end
  end)

  f.header = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.header, 11)
  f.header:SetPoint("TOPLEFT", f, "TOPLEFT", cfg.padding, -3)
  f.header:SetTextColor(GOLD[1], GOLD[2], GOLD[3])
  f.gear = CreateFrame("Button", nil, f)
  f.gear:SetSize(14, 14)
  f.gear:SetPoint("TOPRIGHT", f, "TOPRIGHT", -3, -2)
  f.gear.tex = f.gear:CreateTexture(nil, "ARTWORK")
  f.gear.tex:SetAllPoints(f.gear)
  f.gear.tex:SetTexture("Interface\\Buttons\\UI-OptionsButton")
  f.gear:SetScript("OnClick", function()
    if ns.Options and ns.Options.Open then
      ns.Options.Open()
    end
  end)

  f.slots = {}
  for i = 1, 3 do
    f.slots[i] = Icon(f, i == 1 and cfg.iconSize or cfg.nextSize, cfg)
  end
  f.main = f.slots[1]
  f.glow = Glow(f.main)
  f.cd = Icon(f, cfg.cdSize, cfg)
  f.gcdBg = f:CreateTexture(nil, "BACKGROUND")
  f.gcdBg:SetColorTexture(0, 0, 0, 0.6)
  f.gcd = CreateFrame("StatusBar", nil, f)
  f.gcd:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
  f.gcd:SetStatusBarColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
  f.gcd:SetMinMaxValues(0, 1)
  f.callout = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.callout, 13)
  f.callout:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 2, 3)
  f.callout:SetTextColor(1, 0.25, 0.2)
  f.debug = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.debug, 9)
  f.debug:SetJustifyH("LEFT")

  D.frame = f
  D.Rebuild()
  f:Hide()
  return f
end

-- Re-apply every setting to the existing frame.
function D.Rebuild()
  local f = D.frame
  if not f then
    return
  end
  local cfg = D.Settings()
  f:SetScale(cfg.scale)
  f:SetAlpha(cfg.alpha)
  ApplyBackdrop(f, cfg)
  for _, icon in ipairs({ f.slots[1], f.slots[2], f.slots[3], f.cd }) do
    SetFont(icon.key, cfg.keybindSize)
    icon.key:ClearAllPoints()
    icon.key:SetPoint(cfg.keybindPos, icon, cfg.keybindPos, cfg.keybindPos:find("LEFT") and 2 or -2,
      cfg.keybindPos:find("TOP") and -2 or 2)
    SetFont(icon.name, cfg.nameSize)
  end
  Layout(f, cfg)
  D.SetLocked(ns.db and ns.db.locked)
end

---------------------------------------------------------------------------
-- Updating
---------------------------------------------------------------------------
local function SetIcon(icon, pick, cfg, isMain, labelText)
  if not pick then
    icon:Hide()
    return
  end
  local tex = U.Read(U.Call(C_Spell and C_Spell.GetSpellTexture, pick.id))
  icon.tex:SetTexture(tex or 134400) -- 134400: question mark icon
  icon.source:SetText(SOURCE_TEXT[pick.source] or "")
  icon.key:SetText(cfg.keybind and D.Keybind(pick.id) or "")
  local name = cfg.spellNames and U.Read(U.Call(C_Spell and C_Spell.GetSpellName, pick.id)) or ""
  icon.name:SetText(name or "")
  icon.label:SetText(cfg.labels and labelText or "")
  local alpha = isMain and 1 or cfg.queueAlpha
  if cfg.dimGuesses and (pick.source == "guess" or pick.source == "rules?") then
    alpha = alpha * 0.5
  end
  icon:SetAlpha(alpha)
  icon:Show()
end

local function Translate(label)
  return (tostring(label or ""):gsub("%a+", function(word)
    return L[word]
  end))
end

function D.ShouldShow(inCombat, hasEnemyTarget)
  local cfg = D.Settings()
  if not cfg.hideOutOfCombat then
    return true
  end
  return inCombat or (cfg.showWithTarget and hasEnemyTarget)
end

function D.Update(result, visible)
  local f = D.Create()
  if not visible or not result or not result.main then
    f:Hide()
    return
  end
  local cfg = D.Settings()
  local depth = (ns.db and tonumber(ns.db.queue)) or 3
  local queue = result.queue or { result.main }
  for i = 1, 3 do
    SetIcon(f.slots[i], i <= depth and queue[i] or nil, cfg, i == 1, i == 1 and L["NOW"] or L["NEXT"])
  end
  SetIcon(f.cd, result.cd, cfg, true, L["COOLDOWN"])
  -- "Press now" cue: the GCD (or the current cast) ends within the game's spell queue window, so pressing now
  -- queues the spell with no gap. Timing uses the haste-adjusted GCD we track.
  local queueWindow = (tonumber(U.Read(U.Call(C_CVar and C_CVar.GetCVar, "SpellQueueWindow"))) or 400) / 1000
  local castLeft = select(2, ns.State.CurrentCast()) or 0
  local wait = math.max(ns.State.GCDRemains(), castLeft)
  local pressNow = cfg.pressCue and wait <= queueWindow
  f.pressNow = pressNow
  -- glow on the main icon
  if pressNow and cfg.glow ~= "none" then
    f.glow:Show()
    f.glow:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.8)
  elseif cfg.glow == "none" then
    f.glow:Hide()
  else
    f.glow:Show()
    local a = 0.35
    if cfg.glow == "pulse" then
      a = 0.2 + 0.25 * (0.5 + 0.5 * math.sin(GetTime() * 5))
    end
    f.glow:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], a)
  end
  -- GCD bar
  if cfg.gcdBar then
    local remains, total = ns.State.GCDRemains(), ns.State.GCD()
    f.gcd:SetValue(total > 0 and math.max(0, 1 - remains / total) or 1)
    f.gcd:Show()
    f.gcdBg:Show()
  else
    f.gcd:Hide()
    f.gcdBg:Hide()
  end
  if cfg.header then
    local state = ns.Specs and ns.Specs.current
    f.header:SetText(string.format("DMGAssist · %s · %s", tostring(state and (state.specName or state.key) or "-"),
      Translate(result.modeLabel)))
  end
  local c = result.callout
  if cfg.callout and c then
    local icon = c.spellID and U.Read(U.Call(C_Spell and C_Spell.GetSpellTexture, c.spellID))
    local text = L[c.label]
    if c.seconds then
      text = string.format("%s %d", text, math.ceil(c.seconds))
    end
    if icon then
      text = "|T" .. icon .. ":16|t " .. text
    end
    f.callout:SetText(text)
    f.callout:Show()
  else
    f.callout:Hide()
  end
  if cfg.debugText then
    local parts = {}
    for i, p in ipairs(queue) do
      parts[i] = tostring(p.token) .. "(" .. tostring(p.source) .. ")"
    end
    f.debug:SetText(table.concat(parts, " > ") .. (result.acSpell and ("  AC:" .. tostring(result.acSpell)) or ""))
    f.debug:Show()
  else
    f.debug:Hide()
  end
  f:Show()
end

function D.SetLocked(locked)
  local f = D.Create()
  f:EnableMouse(true) -- right-click mode switching works locked or not; dragging only when unlocked
  f.locked = locked
end
