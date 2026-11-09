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

-- Defaults aim at what most players want: icons only (no frame chrome), keybinds on, a gentle glow, the
-- press-now cue, boss callouts, interrupts and defensives, the real action button highlighted.
D.DEFAULTS = {
  scale = 1.0, alpha = 1.0,
  iconSize = 52, nextSize = 38, spacing = 6, padding = 6,
  queueAlpha = 0.85, dimGuesses = true,
  background = false, bgAlpha = 0.55, border = "none", borderAlpha = 0.6,
  header = false, modeBar = true, keybind = true, keybindSize = 18, keybindPos = "CENTER", keybindColor = "white",
  nameColor = "white",
  spellNames = false, nameSize = 10, labels = false,
  font = "default", outline = "OUTLINE", calloutSize = 14,
  gcdBar = true, glow = "pulse",
  hideOutOfCombat = true, showWithTarget = true, hideMounted = true, hideVehicle = true,
  debugText = false, callout = true, pressCue = true, pressLead = 50, secretBranches = true, interrupt = true, defensive = true,
  highlight = true,
  padLabels = "xbox", rangeTint = true, stackCount = true, stackSize = 14, stackPos = "BOTTOM", weavePos = "TOPLEFT", weaveSize = 45,
}

-- Where the off-GCD badge sits relative to slot 1: { point on the badge, point on slot 1, x, y }.
D.WEAVE_POSITIONS = { { "TOPLEFT", "Top-left corner (docked)" }, { "TOPRIGHT", "Top-right corner" },
  { "LEFT", "Left of the icon" }, { "TOP", "Above the icon" }, { "BOTTOM", "Below the icon" } }
local WEAVE_ANCHOR = {
  TOPLEFT = { "CENTER", "TOPLEFT", 2, -2 }, TOPRIGHT = { "CENTER", "TOPRIGHT", -2, -2 },
  LEFT = { "RIGHT", "LEFT", -4, 0 }, TOP = { "BOTTOM", "TOP", 0, 4 }, BOTTOM = { "TOP", "BOTTOM", 0, -4 },
}

D.STACK_POSITIONS = { { "BOTTOMLEFT", "Bottom left" }, { "TOPLEFT", "Top left" }, { "BOTTOMRIGHT", "Bottom right" },
  { "BOTTOM", "Below the icon" } }

-- Fonts that ship with the game (same files on every client). LibSharedMedia fonts are added when installed.
D.FONTS = {
  { "default", "Game default" },
  { "Fonts\\FRIZQT__.TTF", "Friz Quadrata" },
  { "Fonts\\ARIALN.TTF", "Arial Narrow" },
  { "Fonts\\skurri.ttf", "Skurri" },
  { "Fonts\\MORPHEUS.TTF", "Morpheus" },
}
D.OUTLINES = { { "", "None" }, { "OUTLINE", "Outline" }, { "THICKOUTLINE", "Thick outline" } }

function D.FontChoices()
  local list = {}
  for _, f in ipairs(D.FONTS) do
    list[#list + 1] = f
  end
  local LSM = LibStub and U.Call(LibStub, "LibSharedMedia-3.0", true)
  if LSM and LSM.List and LSM.Fetch then
    for _, name in ipairs(LSM:List("font") or {}) do
      list[#list + 1] = { "lsm:" .. name, name }
    end
  end
  return list
end

local function FontPath(choice)
  if not choice or choice == "default" then
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
  end
  local lsmName = choice:match("^lsm:(.+)$")
  if lsmName then
    local LSM = LibStub and U.Call(LibStub, "LibSharedMedia-3.0", true)
    local path = LSM and U.Call(LSM.Fetch, LSM, "font", lsmName)
    return path or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
  end
  return choice
end

local GOLD = { 1, 0.69, 0 }

-- Text colors offered for keybinds and spell names (Options > Display > Text).
D.TEXT_COLORS = {
  { "white", "White", { 1, 1, 1 } },
  { "gold", "Gold", { 1, 0.82, 0 } },
  { "yellow", "Yellow", { 1, 1, 0.2 } },
  { "orange", "Orange", { 1, 0.55, 0.1 } },
  { "red", "Red", { 1, 0.25, 0.2 } },
  { "pink", "Pink", { 1, 0.45, 0.8 } },
  { "cyan", "Cyan", { 0.3, 0.9, 1 } },
  { "green", "Green", { 0.35, 1, 0.35 } },
  { "grey", "Grey", { 0.7, 0.7, 0.7 } },
}
local COLOR_RGB = {}
for _, c in ipairs(D.TEXT_COLORS) do
  COLOR_RGB[c[1]] = c[3]
end

local function SetColor(fontString, name)
  local rgb = COLOR_RGB[name] or COLOR_RGB.white
  fontString:SetTextColor(rgb[1], rgb[2], rgb[3])
end
local SOURCE_TEXT = {
  simc = "", ["simc+assisted"] = "", ["simc+rules"] = "",
  assisted = "AC", rules = "B", buff = "BUFF", ["rules?"] = "?", guess = "?", pool = "...",
}

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
  if not db.hud.stackPosMoved then
    -- The old default drew the count over slot 1's corner, where it read like part of the spell: move it below.
    db.hud.stackPosMoved = true
    if db.hud.stackPos == "BOTTOMLEFT" then
      db.hud.stackPos = "BOTTOM"
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

-- Controller buttons (the game's own gamepad support): binding names like PAD1 or SHIFT-PADRSHOULDER, shown the
-- way the controller labels them. A modifier the game emulates with a pad button (GamePadEmulateShift etc.)
-- is shown as that button: "LT+A". The game's own glyph markup is used when it gives one.
D.PAD_LABELS = {
  xbox = { PAD1 = "A", PAD2 = "B", PAD3 = "X", PAD4 = "Y", PAD5 = "P5", PAD6 = "P6",
    PADLSHOULDER = "LB", PADRSHOULDER = "RB", PADLTRIGGER = "LT", PADRTRIGGER = "RT",
    PADLSTICK = "LS", PADRSTICK = "RS", PADDUP = "Up", PADDDOWN = "Dn", PADDLEFT = "Lt", PADDRIGHT = "Rt",
    PADBACK = "View", PADFORWARD = "Menu", PADSOCIAL = "Share", PADSYSTEM = "Home",
    PADPADDLE1 = "P1", PADPADDLE2 = "P2", PADPADDLE3 = "P3", PADPADDLE4 = "P4" },
  playstation = { PAD1 = "X", PAD2 = "O", PAD3 = "[]", PAD4 = "/\\", PAD5 = "P5", PAD6 = "P6",
    PADLSHOULDER = "L1", PADRSHOULDER = "R1", PADLTRIGGER = "L2", PADRTRIGGER = "R2",
    PADLSTICK = "L3", PADRSTICK = "R3", PADDUP = "Up", PADDDOWN = "Dn", PADDLEFT = "Lt", PADDRIGHT = "Rt",
    PADBACK = "Create", PADFORWARD = "Opt", PADSOCIAL = "Share", PADSYSTEM = "PS",
    PADPADDLE1 = "P1", PADPADDLE2 = "P2", PADPADDLE3 = "P3", PADPADDLE4 = "P4" },
}

local function PadLabel(button, labels)
  return labels[button] or button:gsub("^PAD", "")
end

function D.KeyText(key)
  if type(key) ~= "string" then
    return nil
  end
  if key:find("PAD", 1, true) then
    local text = U.Get(GetBindingText, key, 1)
    if type(text) == "string" and (text:find("|A", 1, true) or text:find("|T", 1, true)) then
      return text -- the game's own button glyph
    end
    local style = ns.db and ns.db.hud and ns.db.hud.padLabels or "xbox"
    local labels = D.PAD_LABELS[style] or D.PAD_LABELS.xbox
    local parts = {}
    for mod, cvar in pairs({ SHIFT = "GamePadEmulateShift", CTRL = "GamePadEmulateCtrl", ALT = "GamePadEmulateAlt" }) do
      if key:find(mod .. "-", 1, true) then
        local pad = U.Get(GetCVar, cvar)
        parts[#parts + 1] = (type(pad) == "string" and pad:find("^PAD")) and PadLabel(pad, labels)
          or mod:sub(1, 1)
      end
    end
    table.sort(parts)
    local button = key:match("(PAD[%w]+)$")
    parts[#parts + 1] = button and PadLabel(button, labels) or key
    return table.concat(parts, "+")
  end
  local text = U.Get(GetBindingText, key, 1)
  return Shorten(type(text) == "string" and text or key)
end

local function BindingFor(slot, mainPage)
  local page = math.floor((slot - 1) / 12) + 1
  local index = (slot - 1) % 12 + 1
  local command
  if PAGE_COMMAND[page] then
    command = PAGE_COMMAND[page] .. index
  elseif page == mainPage then
    -- The main bar's keys (1-=) press whichever page it shows now: page 1, or a form's / stealth's own page
    -- (Cat 7, Bear 9, Moonkin 10...). A spell on another form's page has no key until you're in that form.
    command = "ACTIONBUTTON" .. index
  end
  if not command then
    return nil, false
  end
  local key = U.Get(GetBindingKey, command)
  if type(key) ~= "string" then
    return nil, false
  end
  return D.KeyText(key), page == mainPage
end

-- Action bar addons bind keys to their own buttons ("CLICK <button>:LeftButton"); the button's action slot is an
-- attribute. Patterns for the common ones (LibActionButton-based Bartender4/ElvUI, and Dominos).
local ALL_BUTTONS = {
  { pattern = "ActionButton%d", count = 12, blizzardMain = true },
  { pattern = "MultiBarBottomLeftButton%d", count = 12 },
  { pattern = "MultiBarBottomRightButton%d", count = 12 },
  { pattern = "MultiBarRightButton%d", count = 12 },
  { pattern = "MultiBarLeftButton%d", count = 12 },
  { pattern = "MultiBar5Button%d", count = 12 },
  { pattern = "MultiBar6Button%d", count = 12 },
  { pattern = "MultiBar7Button%d", count = 12 },
  { pattern = "BT4Button%d", count = 180 },
  { pattern = "DominosActionButton%d", count = 180 },
}
for bar = 1, 15 do
  ALL_BUTTONS[#ALL_BUTTONS + 1] = { pattern = "ElvUI_Bar" .. bar .. "Button%d", count = 12 }
end
local buttonsBySpell = {}

-- The action button that casts this spell (visible preferred), for the highlight.
function D.ButtonFor(spellID)
  if not keymap then
    D.BuildKeymap()
  end
  local b = buttonsBySpell[spellID]
  local base = ns.SpellMap and (ns.SpellMap.baseOf[spellID] or ns.SpellMap.LiveOverride(spellID))
  return b or (base and buttonsBySpell[base]) or nil
end

local function MainPage()
  local bonus = U.Get(C_ActionBar and C_ActionBar.GetBonusBarOffset)
  if type(bonus) == "number" and bonus > 0 then
    return 6 + bonus
  end
  return U.Get(C_ActionBar and C_ActionBar.GetActionBarPage) or 1
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

-- What item an action slot uses: an item, or the item a macro shows (/use 13, /use <name>).
local function SlotItem(slot)
  local kind, id = U.Call(GetActionInfo, slot)
  kind, id = U.Read(kind), U.Read(id)
  if kind == "item" and type(id) == "number" then
    return id
  elseif kind == "macro" and id then
    local _, link = U.Call(GetMacroItem, id)
    link = U.Read(link)
    local item = type(link) == "string" and tonumber(link:match("item:(%d+)"))
    return item
  end
  return nil
end

local itemsOnBar = {}

-- Is this item on an action bar (any slot, bound or not)?
function D.ItemOnBar(item)
  if not keymap then
    D.BuildKeymap()
  end
  return itemsOnBar[item] == true
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
  itemsOnBar = {}
  for slot = 1, 180 do
    local sid = SlotSpell(slot)
    if sid then
      local text, main = BindingFor(slot, mainPage)
      Put(sid, text, main)
    end
    local item = SlotItem(slot)
    if item then
      itemsOnBar[item] = true
      local text, main = BindingFor(slot, mainPage)
      Put("item:" .. item, text, main)
    end
  end
  -- Every button frame we know: Blizzard bars (<BarName>Button<i>, slot in button.action, binding in
  -- button.commandName) and bar addons (slot in an attribute, CLICK bindings). Also remembers which button holds
  -- each spell, for the action bar highlight.
  buttonsBySpell = {}
  for _, def in ipairs(ALL_BUTTONS) do
    for i = 1, def.count do
      local name = def.pattern:format(i)
      local button = _G[name]
      if type(button) == "table" then
        local slot = U.Read(button._state_action) or U.Read(button.action)
        if not slot and button.GetAttribute then
          slot = U.Get(button.GetAttribute, button, "action")
        end
        slot = tonumber(slot)
        local sid = slot and (SlotSpell(slot) or (SlotItem(slot) and ("item:" .. SlotItem(slot))))
        if sid then
          local visible = U.Get(button.IsVisible, button) == true
          if visible or not buttonsBySpell[sid] then
            buttonsBySpell[sid] = button
          end
          local command = U.Read(button.commandName)
          local key = (type(command) == "string" and U.Get(GetBindingKey, command))
            or U.Get(GetBindingKey, "CLICK " .. name .. ":LeftButton")
            or U.Get(GetBindingKey, "CLICK " .. name .. ":Keybind")
          if type(key) == "string" then
            Put(sid, D.KeyText(key), visible and def.blizzardMain)
          end
        end
      end
    end
  end
  keymap, keymapAt = map, GetTime()
  keyCache = {}
  return map
end

-- The key for an item (on-use trinket) on the bars.
function D.ItemKeybind(item)
  if not item then
    return nil
  end
  if not keymap then
    D.BuildKeymap()
  end
  return keymap["item:" .. item]
end

-- The key for a pick: its item's when it is one, else its spell's.
function D.PickKeybind(pick)
  if pick and pick.item then
    return D.ItemKeybind(pick.item)
  end
  return D.Keybind(pick and pick.id)
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
  -- A spell a button turns into (Mind Flay: Insanity on the Mind Flay button): the button's key.
  local base = ns.SpellMap and (ns.SpellMap.baseOf[spellID] or ns.SpellMap.LiveOverride(spellID))
  if not best and base then
    best = keymap[base]
  end
  if not best then
    -- Slots the game knows hold this spell (covers overrides and flyouts).
    local slots = U.Get(C_ActionBar and C_ActionBar.FindSpellActionButtons, spellID)
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
  -- Only a found key is remembered: "no key" is looked up again, since a button can turn into this spell later.
  if best then
    keyCache[spellID] = best
  end
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
  local cfg = D.Settings()
  if not fs:SetFont(FontPath(cfg.font), size, cfg.outline or "OUTLINE") then
    fs:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size, cfg.outline or "OUTLINE")
  end
end

-- Keybind text offset from its anchor: inset from a corner, none when centred.
local function KeyX(pos)
  return pos:find("LEFT") and 2 or (pos:find("RIGHT") and -2 or 0)
end
local function KeyY(pos)
  return pos:find("TOP") and -2 or (pos:find("BOTTOM") and 2 or 0)
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
  SetColor(f.key, cfg.keybindColor)
  f.key:SetPoint(cfg.keybindPos, f, cfg.keybindPos, KeyX(cfg.keybindPos), KeyY(cfg.keybindPos))
  f.name = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.name, cfg.nameSize)
  SetColor(f.name, cfg.nameColor)
  f.name:SetPoint("TOP", f, "BOTTOM", 0, -2)
  f.name:SetWidth(size + 24)
  f.label = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.label, 9)
  f.label:SetPoint("BOTTOM", f, "TOP", 0, 3)
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
  else
    f.header:Hide()
    f.gear:Hide()
  end
  -- Title row: the target mode in force (colour-coded), after the header text when the header is on.
  f.modeText:ClearAllPoints()
  if cfg.header then
    f.modeText:SetPoint("LEFT", f.header, "RIGHT", 6, 0)
  else
    f.modeText:SetPoint("TOPLEFT", f, "TOPLEFT", pad, -3)
  end
  f.modeText:SetShown(cfg.modeBar ~= false)
  if cfg.header or cfg.modeBar ~= false then
    top = top + 34 -- the 12 px title, a gap, the 9 px NOW / NEXT labels and a gap above the icons
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
  -- Nothing below the three slots: interrupts and defensives use slot 1, cooldowns are in the queue, and the
  -- game's own Cooldown Manager shows what is ready.
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
  f:EnableMouse(not db.locked)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    if not (ns.db and ns.db.locked) or (ns.Integrations and ns.Integrations.editMode) then
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

  f.modeText = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.modeText, 12)
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
  -- "not ready yet" wipe and the "press now" flash on slot 1 (see D.RenderTiming)
  f.wipe = f.main:CreateTexture(nil, "OVERLAY")
  f.wipe:SetColorTexture(0, 0, 0, 0.55)
  f.wipe:SetPoint("TOPLEFT", f.main, "TOPLEFT", 0, 0)
  f.wipe:SetPoint("TOPRIGHT", f.main, "TOPRIGHT", 0, 0)
  f.wipe:Hide()
  f.flash = f.main:CreateTexture(nil, "OVERLAY")
  f.flash:SetAllPoints(f.main)
  f.flash:SetColorTexture(1, 1, 0.8, 1)
  if f.flash.SetBlendMode then
    f.flash:SetBlendMode("ADD")
  end
  f.flash:Hide()
  -- every frame while shown: only the timing visuals (cheap), so the flash is on time
  f:SetScript("OnUpdate", function(self)
    if self.timingCfg then
      D.RenderTiming(self, self.timingCfg)
    end
  end)
  -- The other pick of a branch, stacked on the main icon; the game sets which one is visible (see D.Update).
  f.branch = Icon(f, cfg.iconSize, cfg)
  f.branch:SetAllPoints(f.slots[1])
  -- Interrupt drawn over slot 1 when the game must decide (secret "interruptible"/"important"):
  -- kickGate's alpha = important (or 1), kick's alpha = interruptible; nested alpha multiplies = AND.
  -- The icon is opaque, so while visible it covers the normal slot-1 pick underneath.
  f.kickGate = CreateFrame("Frame", nil, f)
  f.kickGate:SetAllPoints(f.slots[1])
  f.kick = Icon(f.kickGate, cfg.iconSize, cfg)
  f.kick:SetAllPoints(f.kickGate)
  f.kick.border = f.kick:CreateTexture(nil, "OVERLAY")
  f.kick.border:SetPoint("TOPLEFT", f.kick, "TOPLEFT", -3, 3)
  f.kick.border:SetPoint("BOTTOMRIGHT", f.kick, "BOTTOMRIGHT", 3, -3)
  f.kick.border:SetColorTexture(1, 0.1, 0.1, 0.7)
  f.kick.border:SetDrawLayer("BACKGROUND")
  -- Defensive that depends on hidden health: drawn over slot 1, visible only when low (decided ones are in
  -- the queue itself, see Defensives.Apply).
  f.def = Icon(f, cfg.iconSize, cfg)
  f.def:SetAllPoints(f.slots[1])
  f.def:SetFrameLevel((f.slots[1]:GetFrameLevel() or 1) + 6)
  -- Counted stacks (Ironfur): our own count from casts, to compare with Blizzard's buff display.
  -- (on its own frame above slot 1: a font string of the HUD frame itself was drawn behind the icon)
  f.stackHolder = CreateFrame("Frame", nil, f)
  f.stackHolder:SetAllPoints(f.slots[1])
  f.stackHolder:SetFrameLevel((f.slots[1]:GetFrameLevel() or 1) + 9)
  f.stack = f.stackHolder:CreateFontString(nil, "OVERLAY")
  f.stack:Hide()
  -- A dark box behind the counter, so it stands out next to slot 1 without covering the icon.
  f.stackBox = f.stackHolder:CreateTexture(nil, "BACKGROUND")
  f.stackBox:SetColorTexture(0, 0, 0, 0.75)
  f.stackBox:Hide()
  -- Off-GCD keep-up (Ironfur): a small badge on slot 1's top-left corner, pressed alongside the GCD spell.
  f.weave = Icon(f, cfg.iconSize, cfg)
  f.weave:SetFrameLevel((f.slots[1]:GetFrameLevel() or 1) + 8)
  f.weave.border = f.weave:CreateTexture(nil, "BACKGROUND")
  f.weave.border:SetPoint("TOPLEFT", f.weave, "TOPLEFT", -2, 2)
  f.weave.border:SetPoint("BOTTOMRIGHT", f.weave, "BOTTOMRIGHT", 2, -2)
  f.weave.border:SetColorTexture(0.3, 0.8, 1, 0.9)
  f.weave:Hide()
  -- Highlight on the real action button that casts slot 1 (our own frame anchored over it; theirs is untouched).
  f.hl = CreateFrame("Frame", nil, UIParent)
  f.hl:SetFrameStrata("HIGH")
  f.hl.tex = f.hl:CreateTexture(nil, "OVERLAY")
  f.hl.tex:SetAllPoints(f.hl)
  f.hl.tex:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.45)
  if f.hl.tex.SetBlendMode then
    f.hl.tex:SetBlendMode("ADD")
  end
  f.hl:Hide()
  f.gcdBg = f:CreateTexture(nil, "BACKGROUND")
  f.gcdBg:SetColorTexture(0, 0, 0, 0.6)
  f.gcd = CreateFrame("StatusBar", nil, f)
  f.gcd:SetStatusBarTexture("Interface\\Buttons\\WHITE8x8")
  f.gcd:SetStatusBarColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
  f.gcd:SetMinMaxValues(0, 1)
  f.callout = f:CreateFontString(nil, "OVERLAY")
  SetFont(f.callout, cfg.calloutSize or 14)
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
  for _, icon in ipairs({ f.slots[1], f.slots[2], f.slots[3] }) do
    SetFont(icon.key, cfg.keybindSize)
    icon.key:ClearAllPoints()
    icon.key:SetPoint(cfg.keybindPos, icon, cfg.keybindPos, KeyX(cfg.keybindPos), KeyY(cfg.keybindPos))
    SetFont(icon.name, cfg.nameSize)
    SetColor(icon.key, cfg.keybindColor)
    SetColor(icon.name, cfg.nameColor)
  end
  for _, icon in ipairs({ f.branch, f.kick, f.def, f.weave }) do
    if icon then
      SetFont(icon.key, cfg.keybindSize)
      SetFont(icon.name, cfg.nameSize)
      SetColor(icon.key, cfg.keybindColor)
      SetColor(icon.name, cfg.nameColor)
    end
  end
  SetFont(f.header, 11)
  SetFont(f.callout, cfg.calloutSize or 14)
  SetFont(f.debug, 9)
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
  local tex = pick.texture or U.Get(C_Spell and C_Spell.GetSpellTexture, pick.id)
  icon.tex:SetTexture(tex or 134400) -- 134400: question mark icon
  icon.source:SetText(SOURCE_TEXT[pick.source] or "")
  icon.key:SetText(cfg.keybind and D.PickKeybind(pick) or "")
  local name = cfg.spellNames and U.Get(C_Spell and C_Spell.GetSpellName, pick.id) or ""
  icon.name:SetText(name or "")
  icon.label:SetText(cfg.labels and labelText or "")
  -- Like the action bars: red when the target is out of this spell's range; on slot 1, blue when it is short of
  -- resource. Only when the game says so (an unreadable answer leaves the icon as it is).
  local r, g, b = 1, 1, 1
  if cfg.rangeTint ~= false and pick.id and not pick.item and U.Get(UnitExists, "target") == true then
    if U.Get(C_Spell and C_Spell.IsSpellInRange, pick.id, "target") == false then
      r, g, b = 1, 0.3, 0.3
    elseif isMain then
      local usable, noPower = U.Call(C_Spell and C_Spell.IsSpellUsable, pick.id)
      if U.Read(usable) == false and U.Read(noPower) == true then
        r, g, b = 0.45, 0.55, 1
      end
    end
  end
  icon.tex:SetVertexColor(r, g, b)
  local alpha = isMain and 1 or cfg.queueAlpha
  if cfg.dimGuesses and (pick.source == "guess" or pick.source == "rules?" or pick.source == "pool") then
    alpha = alpha * 0.5
  end
  icon:SetAlpha(alpha)
  icon:Show()
end

-- The target mode in force, for the title row: "AUTO · AOE 5 targets" (orange) / "AUTO · ST 1 target" (light
-- blue); "AOE (manual)" after the key binding; "AOE ?" when nothing can be counted (the fallback mode is used).
-- AOE once the count reaches the spec's switch point (State.AoeTargets).
local MODE_COLOR = { ST = "|cff66ccff", AOE = "|cffff9933" }

function D.ModeText()
  local S = ns.State
  if not S.combatStart then
    return "" -- the mode only matters in a fight: nothing until combat starts
  end
  local n, label = S.Targets()
  label = tostring(label or "")
  local effective = n >= S.AoeTargets() and "AOE" or "ST"
  local color = MODE_COLOR[effective]
  local word = L[effective]
  if label:find("^AUTO") then
    local unit = n == 1 and L["target"] or L["targets"]
    return string.format("|cff999999%s ·|r %s%s %d %s|r", L["AUTO"], color, word, n, unit) .. D.HeldText()
  elseif S.modeOverride then
    return string.format("%s%s|r |cff999999(%s)|r", color, word, L["manual"]) .. D.HeldText()
  end
  return string.format("%s%s|r", color, word) .. D.HeldText()
end

-- "· 1 held" after the mode while the player is holding skipped spells this fight.
function D.HeldText()
  local n = 0
  for _ in pairs(ns.Engine.held or {}) do
    n = n + 1
  end
  if n == 0 then
    return ""
  end
  return string.format(" |cff999999· %d %s|r", n, L["held"])
end

---------------------------------------------------------------------------
-- Rendering secrets without reading them
---------------------------------------------------------------------------
-- Widgets accept secret values (SetAlpha/SetText/SetValue: SecretArguments "AllowedWhenTainted"), and curves
-- evaluate secret inputs (UnitPowerPercent(unit, powerType, unmodified, curve), input 0..1). So for a pick that
-- depends on one hidden resource, a step curve over that resource yields the icon's alpha: the game shows the
-- right icon, and DMGAssist never learns the value.
local curveCache = {}

local function BranchCurve(branch, wantTrue)
  if not (C_CurveUtil and C_CurveUtil.CreateCurve) then
    return nil
  end
  local key = branch.pt .. ":" .. branch.max .. ":" .. tostring(wantTrue)
  for v = 0, branch.max do
    key = key .. (branch.truth[v] and "1" or "0")
  end
  local c = curveCache[key]
  if not c then
    c = U.Call(C_CurveUtil.CreateCurve)
    if not c then
      return nil
    end
    local step = Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step or 1
    c:SetType(step)
    for v = 0, branch.max do
      local on = branch.truth[v] == wantTrue
      -- points half a step early so floating point percentages never land on the previous value
      local x = v == 0 and 0 or (v - 0.5) / branch.max
      c:AddPoint(x, on and 1 or 0)
    end
    curveCache[key] = c
  end
  return c
end

local function RenderBranch(f, result, cfg)
  local b = result.branch
  if not (cfg.secretBranches and b and b.otherwise) then
    f.branch:Hide()
    return false
  end
  local curveTrue, curveFalse = BranchCurve(b, true), BranchCurve(b, false)
  local alphaTrue = curveTrue and U.Call(UnitPowerPercent, "player", b.pt, false, curveTrue)
  local alphaFalse = curveFalse and U.Call(UnitPowerPercent, "player", b.pt, false, curveFalse)
  if alphaTrue == nil or alphaFalse == nil then
    f.branch:Hide()
    return false
  end
  SetIcon(f.branch, b.pick, cfg, true, L["NOW"])
  SetIcon(f.slots[1], b.otherwise, cfg, true, L["NOW"])
  f.branch:SetAlpha(alphaTrue)       -- possibly secret: only the game knows which one is visible
  f.slots[1]:SetAlpha(alphaFalse)
  f.branch.source:SetText("")
  f.slots[1].source:SetText("")
  return true
end

-- Our interrupt, shown while the target casts. Interruptible and "important" (Blizzard: lethal if not
-- interrupted) may be secret; they drive alpha directly (SetAlphaFromBoolean accepts secret booleans).
local INTERRUPT_TOKENS = { "kick", "counterspell", "pummel", "wind_shear", "mind_freeze", "skull_bash", "rebuke",
  "spear_hand_strike", "disrupt", "counter_shot", "muzzle", "silence", "quell", "solar_beam", "spell_lock",
  "axe_toss" }

function D.InterruptSpell(includeHidden)
  local M = ns.SpellMap
  for _, token in ipairs(INTERRUPT_TOKENS) do
    local id = M.SpellID(token)
    if id and (includeHidden or not ns.Choices.IsHidden(id)) then
      M.unresolved[token] = nil
      return id
    end
    M.unresolved[token] = nil
  end
  return nil
end

local function TargetCast()
  local c = { U.Call(UnitCastingInfo, "target") }
  if c[1] ~= nil then
    return true, c[8], c[9]   -- casting, notInterruptible, spellID (either may be secret)
  end
  c = { U.Call(UnitChannelInfo, "target") }
  if c[1] ~= nil then
    return true, c[7], c[8]
  end
  return false
end
D.TargetCast = TargetCast

local function SetAlphaBool(frame, value, ifTrue, ifFalse)
  if U.IsSecret(value) then
    U.Call(frame.SetAlphaFromBoolean, frame, value, ifTrue, ifFalse)
  elseif value then
    frame:SetAlpha(ifTrue)
  else
    frame:SetAlpha(ifFalse)
  end
end

-- result.interrupt from Interrupts.Evaluate: "decided" ones are already slot 1 of the queue; "render" ones are
-- drawn over slot 1 with secret-driven alpha.
local function RenderInterrupt(f, result, cfg)
  local intr = result.interrupt
  if not (cfg.interrupt and intr and intr.how == "render") then
    f.kickGate:Hide()
    f.kick:Hide()
    return
  end
  SetIcon(f.kick, { id = intr.id, source = "interrupt" }, cfg, true, L["INTERRUPT"])
  f.kickGate:Show()
  SetAlphaBool(f.kick, intr.notInterruptible, 0, 1)
  if intr.needImportant then
    SetAlphaBool(f.kickGate, intr.important, 1, 0)
  else
    f.kickGate:SetAlpha(1)
  end
end

-- Defensive: decided (boss mod / readable health) -> shown; render -> alpha from a step curve on the player's
-- secret health percent (UnitHealthPercent with a curve, input 0..1): visible only at or below the threshold.
local healthCurves = {}

local function RenderDefensive(f, result, cfg)
  local d = result.defensive
  if not (cfg.defensive and d and d.how == "render") then
    f.def:Hide()
    return
  end
  SetIcon(f.def, { id = d.id, source = "defensive" }, cfg, true, L["DEFENSIVE"])
  if d.how == "render" then
    local key = string.format("%.2f", d.threshold)
    local c = healthCurves[key]
    if not c and C_CurveUtil and C_CurveUtil.CreateCurve then
      c = U.Call(C_CurveUtil.CreateCurve)
      if c then
        c:SetType(Enum and Enum.LuaCurveType and Enum.LuaCurveType.Step or 1)
        c:AddPoint(0, 1)
        c:AddPoint(d.threshold + 0.0001, 0)
        healthCurves[key] = c
      end
    end
    local alpha = c and U.Call(UnitHealthPercent, "player", true, c)
    if alpha == nil then
      f.def:Hide()
      return
    end
    f.def:SetAlpha(alpha)
  end
end

local function RenderWeave(f, result, cfg)
  local w = result.weave
  if not w then
    f.weave:Hide()
    return
  end
  local size = math.floor((cfg.iconSize or 48) * (tonumber(cfg.weaveSize) or 45) / 100)
  local a = WEAVE_ANCHOR[cfg.weavePos or "TOPLEFT"] or WEAVE_ANCHOR.TOPLEFT
  f.weave:ClearAllPoints()
  f.weave:SetSize(size, size)
  f.weave:SetPoint(a[1], f.slots[1], a[2], a[3], a[4])
  SetIcon(f.weave, w, cfg, true, "")
  f.weave.name:SetText("")
end

-- "<icon> 2/3": our counted stacks of the spec's stacking keep-up, and the target (orange when below it).
local function RenderStacks(f, cfg)
  local X = ns.Essentials
  local k = cfg.stackCount ~= false and ns.db and X and X.CountedKeepUp()
  if k and k.kind == "stacks" and ns.db.tankEssentials == false then
    k = nil
  end
  if k and k.kind == "atonement" and (tonumber(U.Get(GetNumGroupMembers)) or 0) < 2 then
    k = nil -- solo there is no one to keep Atonement on
  end
  if not k then
    f.stack:Hide()
    f.stackBox:Hide()
    return
  end
  local n = X.Stacks(k.id)
  local want = tonumber(ns.db[k.setting]) or (k.kind == "atonement" and 5 or 3)
  local size = tonumber(cfg.stackSize) or 14
  SetFont(f.stack, size)
  -- Below the icon by default: drawn over it, the count read like part of the recommendation.
  local pos = cfg.stackPos or "BOTTOM"
  f.stack:ClearAllPoints()
  if pos == "BOTTOM" then
    f.stack:SetPoint("TOP", f.slots[1], "BOTTOM", 0, -4)
  else
    f.stack:SetPoint(pos, f.slots[1], pos, pos:find("LEFT") and 2 or -2, pos:find("TOP") and -2 or 2)
  end
  -- A plain label, never a spell icon: the count is information, not something to press.
  local icon = "|cffbbbbbb" .. (k.kind == "atonement" and L["Atonement"] or
    tostring(U.Get(C_Spell and C_Spell.GetSpellName, k.id) or "")) .. "|r "
  local color = (want > 0 and n < want) and "|cffff9933" or "|cffffffff"
  f.stack:SetText(string.format("%s%s%d|r", icon, color, n) .. (want > 0 and ("|cff999999/" .. want .. "|r") or ""))
  f.stack:Show()
  f.stackBox:ClearAllPoints()
  f.stackBox:SetPoint("TOPLEFT", f.stack, "TOPLEFT", -4, 3)
  f.stackBox:SetPoint("BOTTOMRIGHT", f.stack, "BOTTOMRIGHT", 4, -3)
  f.stackBox:Show()
end

local function RenderHighlight(f, result, cfg)
  local pick = result.queue and result.queue[1] or result.main
  local button = cfg.highlight and pick and D.ButtonFor(pick.id)
  if not (button and U.Get(button.IsVisible, button) == true) then
    f.hl:Hide()
    return
  end
  if f.hl.button ~= button then
    f.hl:ClearAllPoints()
    f.hl:SetPoint("TOPLEFT", button, "TOPLEFT", -1, 1)
    f.hl:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 1, -1)
    f.hl.button = button
  end
  f.hl:SetAlpha(f.pressNow and 1 or (0.55 + 0.25 * math.sin(GetTime() * 5)))
  f.hl:Show()
end

-- Timing on slot 1, redrawn every frame (OnUpdate) so the cue lands on the right moment:
--   wait   = the longer of the GCD and our cast still running (both timed by State, see S.GCDRemains /
--            S.CurrentCast: the game hides them in combat, so they come from our cast events and measured haste)
--   not ready: a dark wipe over slot 1 that drains as the wait runs out (and the GCD bar fills)
--   ready:  a bright flash `pressLead` seconds before the moment (default 50 ms: reaction time), then a steady glow
local FLASH = 0.35

-- Your connection: a press takes your world latency to reach the server, and the game queues a press made up to
-- SpellQueueWindow before the GCD ends. So "press now" comes that much earlier (never more than the queue window,
-- or the press would be dropped). Read every few seconds; both are always readable.
local latAt, latency = 0, 0
function D.Latency()
  local now = GetTime()
  if now - latAt > 5 then
    latAt = now
    local world = U.Read((select(4, U.Call(GetNetStats))))
    local queue = tonumber(U.Get(GetCVar, "SpellQueueWindow")) or 400
    latency = 0
    if type(world) == "number" and world > 0 then
      latency = math.min(world, queue) / 1000
    end
  end
  return latency
end

function D.RenderTiming(f, cfg)
  local castLeft = select(2, ns.State.CurrentCast()) or 0
  local busy = math.max(ns.State.GCDRemains(), castLeft)
  local id = f.shownId
  -- Rechecks happen behind the scenes: what slot 1 shows only changes when the answer does. A press (a new GCD or
  -- cast starting) or a different spell in slot 1 starts a new moment; until then, once a spell is ready it stays
  -- ready and it flashes once (a recheck that briefly read "not yet" made Holy Shock strobe, 2026-11-09).
  if busy > (f.lastBusy or 0) + 0.05 or id ~= f.momentId then
    f.readyFor, f.flashedFor, f.momentId = nil, nil, id
  end
  f.lastBusy = busy
  -- A slot 1 shown a moment early (its cooldown still running, see Engine DecideAhead) counts as not ready too:
  -- timed by its own cooldown clock, every frame, so the wipe drains smoothly.
  local cdLeft = 0
  if f.readyAt and f.readyFor ~= id then
    local left = f.readyId and ns.State.CooldownRemains(f.readyId)
    if type(left) ~= "number" then
      left = 0 -- no clock to show: don't guess a shade
    end
    cdLeft = math.min(left, f.readyAt - GetTime() + 0.5)
  end
  local wait = math.max(busy, cdLeft)
  -- A long shade goes in the report with where it came from (global cooldown, a cast or channel, a cooldown), so a
  -- "slot 1 shaded while ready on my bar" report says which timer was wrong. Once per shade, at most 20 a fight.
  if wait > 1.0 and not f.shadeLogged then
    f.shadeLogged = true
    D.shadesLogged = (D.shadesLogged or 0) + 1
    if D.shadesLogged <= 20 then
      local castID = ns.State.CurrentCast()
      U.Log("shade", { spell = id, wait = string.format("%.1f", wait),
        gcd = string.format("%.1f", ns.State.GCDRemains()), cast = castID,
        castLeft = string.format("%.1f", castLeft), cd = string.format("%.1f", cdLeft),
        castSource = ns.State.castSource })
    end
  elseif wait <= 0.2 then
    f.shadeLogged = nil
  end
  -- Length of this wait period, for the wipe and the bar: a jump up means a new GCD or cast started.
  if not f.waitTotal or wait > (f.lastWait or 0) + 0.05 then
    f.waitTotal = math.max(wait, 0.01)
  end
  f.lastWait = wait
  local lead = (tonumber(cfg.pressLead) or 50) / 1000 + D.Latency()
  local ready = wait <= lead
  local now = GetTime()
  if ready then
    f.readyFor = id
    if not f.pressNow and f.flashedFor ~= id then
      f.flashAt, f.flashedFor = now, id -- the moment it became ready: one flash
    end
  end
  f.pressNow = ready
  local frac = ready and 0 or math.min(1, wait / f.waitTotal)
  -- dark wipe: the remaining part of the wait, from the top of the icon down
  if cfg.pressCue and frac > 0 then
    f.wipe:SetHeight(math.max(1, f.main:GetHeight() * frac))
    f.wipe:Show()
  else
    f.wipe:Hide()
  end
  -- glow / flash
  if cfg.pressCue and ready and f.flashAt and now - f.flashAt < FLASH then
    local t = (now - f.flashAt) / FLASH
    f.glow:Show()
    f.glow:SetColorTexture(1, 1, 0.75, 1 - 0.5 * t)
    f.flash:SetAlpha(0.9 * (1 - t))
    f.flash:Show()
  else
    f.flash:Hide()
    if cfg.glow == "none" then
      f.glow:Hide()
    elseif ready and cfg.pressCue then
      f.glow:Show()
      f.glow:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 0.8)
    else
      f.glow:Show()
      local a = 0.35
      if cfg.glow == "pulse" then
        a = 0.2 + 0.25 * (0.5 + 0.5 * math.sin(now * 5))
      end
      f.glow:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], ready and a or a * 0.5)
    end
  end
  if cfg.gcdBar then
    f.gcd:SetValue(1 - frac)
    f.gcd:Show()
    f.gcdBg:Show()
  else
    f.gcd:Hide()
    f.gcdBg:Hide()
  end
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
    if f.hl then
      f.hl:Hide()
    end
    return
  end
  local cfg = D.Settings()
  local depth = (ns.db and tonumber(ns.db.queue)) or 3
  local queue = result.queue or { result.main }
  for i = 1, 3 do
    SetIcon(f.slots[i], i <= depth and queue[i] or nil, cfg, i == 1, i == 1 and L["NOW"] or L["NEXT"])
  end
  f.branchShown = RenderBranch(f, result, cfg)
  RenderInterrupt(f, result, cfg)
  RenderDefensive(f, result, cfg)
  RenderWeave(f, result, cfg)
  RenderStacks(f, cfg)
  f.timingCfg = cfg
  -- Blizzard's assistant names this very spell right now: no cooldown shade (our clock for a charge can be a second
  -- or two slow, and a late shade costs damage; only the global cooldown still shades).
  local early = result.main.readyAt and result.main.id ~= result.acSpell
  f.readyAt = early and result.main.readyAt or nil
  f.readyId = early and result.main.id or nil
  f.shownId = result.main.id
  D.RenderTiming(f, cfg)
  if cfg.header then
    local state = ns.Specs and ns.Specs.current
    f.header:SetText(string.format("DMGAssist · %s", tostring(state and (state.specName or state.key) or "-")))
  end
  if cfg.modeBar ~= false then
    local mode = D.ModeText()
    if cfg.header and mode ~= "" then
      mode = "|cff999999·|r " .. mode
    end
    f.modeText:SetText(mode)
  end
  local c = result.callout
  if cfg.callout and c then
    local icon = c.spellID and U.Get(C_Spell and C_Spell.GetSpellTexture, c.spellID)
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
  RenderHighlight(f, result, cfg)
  f:Show()
end

-- Locked = click-through (never blocks clicks on the world behind it). Unlocked = drag to move, right-click
-- cycles the target mode; the gear (header) stays clickable either way.
function D.SetLocked(locked)
  local f = D.Create()
  f:EnableMouse(not locked)
  f.locked = locked
end
