-- CLF HUD -- Frame creation and display
local _, CLF = ...
local L = CLF.L or setmetatable({}, {__index = function(_, k) return k end})

local mainFrame = nil
local iconFrames = {}
local resourceBar = nil -- deprecated, kept for compat
local keybindTexts = {}
local spellNameTexts = {}
local cooldownTexts = {}
local cooldownSweeps = {}
local sweepState = {}
local queueLabels = {}
local conditionText = nil
local statusText = nil
local glowFrames = {}
local gcdSpark = nil
local consumableBar = nil

local mathMin = math.min
local CLASS_COLOR = { 0.769, 0.118, 0.227 }
local GOLD = { 0.83, 0.65, 0.2 }

local function Detaint(val)
  if type(val) == "nil" then return nil end
  if issecretvalue and issecretvalue(val) then return nil end
  return tonumber(val)
end
local DetaintStr = CLF.DetaintStr
local DetaintBool = CLF.DetaintBool

local function CreateGlowFrame(parent, size)
  local config = CLF_Config or CLF_DefaultConfig
  local hud = config and config.hud or {}
  local glowStyle = hud.glowStyle or "gold"

  local glow = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  glow:SetSize(size + 8, size + 8)
  glow:SetPoint("CENTER")
  if glowStyle == "none" then
    return glow
  end
  glow:SetBackdrop({
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 2,
  })
  if glowStyle == "class" then
    glow:SetBackdropBorderColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 0.7)
  else
    glow:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.7)
  end
  glow:Hide()
  return glow
end

function CLF.CreateHUD()
  if mainFrame then
    mainFrame:Hide()
    mainFrame:SetParent(nil)
    mainFrame:ClearAllPoints()
    mainFrame = nil
  end
  local existing = _G["CLF_MainFrame"]
  if existing then
    existing:Hide()
    existing:SetParent(nil)
    existing:ClearAllPoints()
  end

  iconFrames = {}
  keybindTexts = {}
  spellNameTexts = {}
  cooldownTexts = {}
  cooldownSweeps = {}
  sweepState = {}
  glowFrames = {}
  queueLabels = {}
  gcdSpark = nil
  resourceBar = nil
  statusText = nil
  conditionText = nil
  consumableBar = nil

  local config = CLF_Config or CLF_DefaultConfig
  if not config then config = { hud = {}, spec = { classColor = "#FFFFFF" } } end
  local hud = config.hud or {}

  local scale = hud.scale or 1.2
  local iconSize = hud.iconSize or 48
  local queueSlots = math.min(hud.queueSlots or 3, 3)
  local padding = hud.framePadding or 16
  local spacing = hud.iconSpacing or 14
  local posX = hud.positionX or 50
  local posY = hud.positionY or 70

  -- Main container
  mainFrame = CreateFrame("Frame", "CLF_MainFrame", UIParent, "BackdropTemplate")
  mainFrame:SetScale(scale)
  mainFrame:SetAlpha(hud.opacity or 0.95)

  -- Calculate frame size -- always include all queue slots in the background
  local predSize = hud.predIconSize or 34
  local totalWidth = iconSize + padding * 2
  if queueSlots > 1 then
    totalWidth = totalWidth + (queueSlots - 1) * (predSize + spacing)
  end
  local minWidth = hud.minFrameWidth or 220
  if totalWidth < minWidth then totalWidth = minWidth end
  local totalHeight = iconSize + padding * 2 + 40 -- extra for resource bar + labels

  mainFrame:SetSize(totalWidth, totalHeight)
  mainFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT",
    UIParent:GetWidth() * posX / 100,
    UIParent:GetHeight() * (100 - posY) / 100
  )

  local borderStyle = hud.borderStyle or "thin"
  local edgeSize = borderStyle == "thick" and 2 or (borderStyle == "none" and 0 or 1)
  local borderAlpha = borderStyle == "none" and 0 or (hud.borderOpacity or 0.25)
  local bgAlpha = hud.bgOpacity or 0.75

  mainFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = math.max(edgeSize, 1),
  })
  mainFrame:SetBackdropColor(0.05, 0.05, 0.08, bgAlpha)
  mainFrame:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], borderAlpha)

  -- Always set movable so we can toggle lock at runtime
  mainFrame:SetMovable(true)
  mainFrame:SetClampedToScreen(true)
  mainFrame:EnableMouse(true)
  mainFrame:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" and CLF._positionLocked then
      CLF.CycleMode()
    end
  end)

  -- Drag overlay -- covers the entire frame when unlocked, hidden when locked
  local dragOverlay = CreateFrame("Frame", "CLF_DragOverlay", mainFrame, "BackdropTemplate")
  dragOverlay:SetAllPoints(mainFrame)
  dragOverlay:SetFrameLevel(mainFrame:GetFrameLevel() + 20)
  dragOverlay:EnableMouse(true)
  dragOverlay:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 2,
  })
  dragOverlay:SetBackdropColor(GOLD[1] * 0.15, GOLD[2] * 0.15, GOLD[3] * 0.15, 0.5)
  dragOverlay:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
  dragOverlay:RegisterForDrag("LeftButton")
  dragOverlay:SetScript("OnDragStart", function()
    if CLF._positionLocked then return end
    mainFrame:StartMoving()
  end)
  dragOverlay:SetScript("OnDragStop", function()
    mainFrame:StopMovingOrSizing()
    local point, relativeTo, relativePoint, x, y = mainFrame:GetPoint()
    if not CLF_Position then CLF_Position = {} end
    CLF_Position.point = point
    CLF_Position.relPoint = relativePoint
    CLF_Position.x = x
    CLF_Position.y = y
  end)
  dragOverlay:SetScript("OnMouseUp", function(self, button)
    if button == "RightButton" then
      CLF.ShowDragMenu(self)
    end
  end)

  local dragLabel = dragOverlay:CreateFontString(nil, "OVERLAY")
  dragLabel:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
  dragLabel:SetPoint("CENTER", dragOverlay, "CENTER", 0, 0)
  dragLabel:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 1.0)
  dragLabel:SetText(L["DRAG_TO_MOVE"])

  local dragHint = dragOverlay:CreateFontString(nil, "OVERLAY")
  dragHint:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
  dragHint:SetPoint("BOTTOM", dragOverlay, "BOTTOM", 0, 4)
  dragHint:SetTextColor(0.7, 0.7, 0.7, 0.8)
  dragHint:SetText(L["RIGHT_CLICK_OPTIONS"])

  dragOverlay:SetScript("OnEnter", function(self)
    self:SetBackdropColor(GOLD[1] * 0.25, GOLD[2] * 0.25, GOLD[3] * 0.25, 0.65)
    self:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 1.0)
  end)
  dragOverlay:SetScript("OnLeave", function(self)
    self:SetBackdropColor(GOLD[1] * 0.15, GOLD[2] * 0.15, GOLD[3] * 0.15, 0.5)
    self:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.9)
  end)

  CLF._dragOverlay = dragOverlay

  CLF._positionLocked = hud.lockPosition or false
  if CLF._positionLocked then
    dragOverlay:Hide()
  end

  -- Status text (ST/AoE indicator)
  statusText = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  statusText:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", padding, -4)
  local headerSize = hud.headerFontSize or 11
  statusText:SetFont("Fonts\\FRIZQT__.TTF", headerSize, "OUTLINE")
  statusText:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 0.6)
  -- Create icon frames
  local startX = padding
  for i = 1, queueSlots do
    local size = (i == 1) and iconSize or predSize
    local frame = CreateFrame("Frame", "CLF_Icon" .. i, mainFrame, "BackdropTemplate")
    frame:SetSize(size, size)

    if i == 1 then
      frame:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", padding, padding + 20)
    else
      frame:SetPoint("LEFT", iconFrames[i - 1], "RIGHT", spacing, 0)
    end

    frame:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.6)
    frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.5)
    frame:SetAlpha(1)

    -- Spell icon texture
    frame.icon = frame:CreateTexture(nil, "ARTWORK")
    frame.icon:SetAllPoints()
    frame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    -- Glow frame
    glowFrames[i] = CreateGlowFrame(frame, size)

    -- Keybind text (always created, visibility controlled by RefreshHUD)
    local kbText = frame:CreateFontString(nil, "OVERLAY")
    kbText:SetFont("Fonts\\FRIZQT__.TTF", (i == 1) and (hud.keybindFontSize or 11) or math.max(7, (hud.keybindFontSize or 11) - 2), "OUTLINE")
    kbText:SetTextColor(1, 1, 1, 0.85)
    kbText:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
    keybindTexts[i] = kbText

    -- Spell name text (always created, visibility controlled by RefreshHUD)
    local nameText = frame:CreateFontString(nil, "OVERLAY")
    local fontSize = (i == 1) and (hud.spellNameFontSize or 10) or math.max(7, (hud.spellNameFontSize or 10) - 1)
    nameText:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
    nameText:SetTextColor(0.9, 0.9, 0.9, 0.8)
    local snPad = hud.spellNamePadding or 6
    nameText:SetPoint("TOP", frame, "BOTTOM", 0, -snPad)
    nameText:SetWidth(size + 8)
    nameText:SetWordWrap(false)
    spellNameTexts[i] = nameText

    -- Cooldown countdown text (always created, visibility controlled by RefreshHUD)
    local cdTextPos = hud.cdTextPosition or "CENTER"
    local cdTextSize = (i == 1) and (hud.cdTextSize or 14) or math.max(7, (hud.cdTextSize or 14) - 4)
    local cdTextOffX = hud.cdTextOffsetX or 0
    local cdTextOffY = hud.cdTextOffsetY or 0
    local cdText = frame:CreateFontString(nil, "OVERLAY")
    cdText:SetFont("Fonts\\FRIZQT__.TTF", cdTextSize, "OUTLINE")
    cdText:SetTextColor(1, 0.9, 0.3, 0.95)
    cdText:SetPoint(cdTextPos, frame, cdTextPos, cdTextOffX, cdTextOffY)
    cooldownTexts[i] = cdText

    local sweep = CreateFrame("Cooldown", "CLF_CDSweep" .. i, frame, "CooldownFrameTemplate")
    sweep:SetAllPoints(frame.icon)
    sweep:SetDrawEdge(true)
    sweep:SetDrawSwipe(true)
    sweep:SetSwipeColor(0, 0, 0, 0.65)
    sweep:SetHideCountdownNumbers(true)
    sweep:SetReverse(false)
    sweep:Hide()
    cooldownSweeps[i] = sweep

    local gcdOverlay = frame:CreateTexture(nil, "OVERLAY")
    gcdOverlay:SetAllPoints(frame.icon)
    gcdOverlay:SetColorTexture(0, 0, 0, 0.7)
    gcdOverlay:Hide()
    frame.gcdOverlay = gcdOverlay

    if i == 1 then
      local readyFlash = frame:CreateTexture(nil, "OVERLAY", nil, 2)
      readyFlash:SetPoint("TOPLEFT", frame, "TOPLEFT", -3, 3)
      readyFlash:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 3, -3)
      readyFlash:SetColorTexture(0.2, 1, 0.3, 1)
      readyFlash:Hide()
      frame.readyFlash = readyFlash

      local barHeight = math.max(4, math.floor(size * 0.20))
      local barBg = frame:CreateTexture(nil, "OVERLAY", nil, 2)
      barBg:SetPoint("BOTTOMLEFT", frame.icon, "BOTTOMLEFT", 0, 0)
      barBg:SetPoint("BOTTOMRIGHT", frame.icon, "BOTTOMRIGHT", 0, 0)
      barBg:SetHeight(barHeight)
      barBg:SetColorTexture(0, 0, 0, 0.5)
      barBg:Hide()
      frame.gcdBarBg = barBg

      local barFill = frame:CreateTexture(nil, "OVERLAY", nil, 3)
      barFill:SetPoint("BOTTOMLEFT", frame.icon, "BOTTOMLEFT", 0, 0)
      barFill:SetHeight(barHeight)
      barFill:SetWidth(1)
      barFill:SetColorTexture(0.2, 1, 0.3, 0.85)
      barFill:Hide()
      frame.gcdBarFill = barFill
    end

    -- Queue label (NOW / NEXT / +N) -- always created, visibility controlled by RefreshHUD
    local ql = frame:CreateFontString(nil, "OVERLAY")
    if i == 1 then
      ql:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
      ql:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 0.8)
      ql:SetPoint("BOTTOM", frame, "TOP", 0, 4)
      ql:SetText(L["NOW"])
    else
      ql:SetFont("Fonts\\FRIZQT__.TTF", 7, "OUTLINE")
      ql:SetTextColor(0.6, 0.6, 0.6, 0.5)
      ql:SetPoint("BOTTOM", frame, "TOP", 0, 1)
      ql:SetText(i == 2 and L["NEXT"] or ("+" .. i))
    end
    queueLabels[i] = ql

    iconFrames[i] = frame
  end

  -- GCD spark bar (always created, visibility controlled by RefreshHUD)
  if iconFrames[1] then
    local sparkBg = CreateFrame("Frame", nil, iconFrames[1], "BackdropTemplate")
    sparkBg:SetSize(iconSize, 3)
    sparkBg:SetPoint("BOTTOM", iconFrames[1], "BOTTOM", 0, -1)
    sparkBg:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
    })
    sparkBg:SetBackdropColor(0, 0, 0, 0.4)

    gcdSpark = sparkBg:CreateTexture(nil, "OVERLAY")
    gcdSpark:SetPoint("LEFT")
    gcdSpark:SetHeight(3)
    gcdSpark:SetTexture("Interface\\Buttons\\WHITE8x8")
    gcdSpark:SetVertexColor(GOLD[1], GOLD[2], GOLD[3], 0.8)
    gcdSpark:SetWidth(1)
    gcdSpark.parent = sparkBg
  end

  -- Condition text (always created, visibility controlled by RefreshHUD)
  conditionText = mainFrame:CreateFontString(nil, "OVERLAY")
  conditionText:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
  conditionText:SetTextColor(0.5, 0.5, 0.5, 0.5)
  conditionText:SetPoint("TOP", mainFrame, "BOTTOM", 0, -4)
  conditionText:SetWidth(totalWidth)
  conditionText:SetWordWrap(false)

  -- Gear button (opens settings panel)
  local gearBtn = CreateFrame("Button", "CLF_GearBtn", mainFrame)
  gearBtn:SetSize(14, 14)
  gearBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -4, -4)
  gearBtn:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
  gearBtn:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
  gearBtn:SetAlpha(0.4)
  gearBtn:SetScript("OnEnter", function(self) self:SetAlpha(1) end)
  gearBtn:SetScript("OnLeave", function(self) self:SetAlpha(0.4) end)
  gearBtn:SetScript("OnClick", function() CLF.ToggleSettings() end)
  gearBtn:SetFrameLevel(mainFrame:GetFrameLevel() + 5)

  consumableBar = CreateFrame("Frame", "CLF_ConsumableBar", mainFrame)
  consumableBar:SetSize(totalWidth, 68)
  consumableBar:SetPoint("TOP", mainFrame, "BOTTOM", 0, -4)
  consumableBar:Hide()

  local consHeaderSize = hud.consumablesFontSize or 11
  local cbHeader = consumableBar:CreateFontString(nil, "OVERLAY")
  cbHeader:SetFont("Fonts\\FRIZQT__.TTF", consHeaderSize, "OUTLINE")
  cbHeader:SetPoint("TOPLEFT", consumableBar, "TOPLEFT", padding, 0)
  cbHeader:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 0.7)
  cbHeader:SetText("Consumables Expired")
  consumableBar._header = cbHeader

  local CONS_ICONS = {
    flask = "Interface\\Icons\\INV_Alchemy_Elixir_04",
    food = "Interface\\Icons\\INV_Misc_Food_15",
    weaponEnh = "Interface\\Icons\\INV_Stone_SharpeningStone_01",
    augmentRune = "Interface\\Icons\\INV_Misc_Rune_12",
  }
  local CONS_LABELS = {
    flask = "Flask",
    food = "Food",
    weaponEnh = "Weapon",
    augmentRune = "Rune",
  }
  local ROW_ORDER = {
    { "flask", "food" },
    { "weaponEnh", "augmentRune" },
  }

  consumableBar._icons = {}
  consumableBar._labels = {}
  consumableBar._rows = ROW_ORDER
  consumableBar._consIcons = CONS_ICONS
  consumableBar._consLabels = CONS_LABELS

  local consLabelSize = math.max(8, consHeaderSize - 1)
  for rowIdx, row in ipairs(ROW_ORDER) do
    local yOff = -24 - (rowIdx - 1) * 20
    for colIdx, catKey in ipairs(row) do
      local xOff = padding + (colIdx - 1) * (totalWidth * 0.5)

      local icon = consumableBar:CreateTexture(nil, "ARTWORK")
      icon:SetSize(14, 14)
      icon:SetPoint("TOPLEFT", consumableBar, "TOPLEFT", xOff, yOff)
      icon:SetTexture(CONS_ICONS[catKey])
      icon:Hide()
      consumableBar._icons[catKey] = icon

      local lbl = consumableBar:CreateFontString(nil, "OVERLAY")
      lbl:SetFont("Fonts\\FRIZQT__.TTF", consLabelSize, "OUTLINE")
      lbl:SetPoint("LEFT", icon, "RIGHT", 4, 0)
      lbl:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 0.7)
      lbl:SetText(CONS_LABELS[catKey])
      lbl:Hide()
      consumableBar._labels[catKey] = lbl
    end
  end

  -- Restore saved position
  if CLF_Position and CLF_Position.x then
    mainFrame:ClearAllPoints()
    local savedPoint = CLF_Position.point or "BOTTOMLEFT"
    local savedRelPoint = CLF_Position.relPoint or "BOTTOMLEFT"
    mainFrame:SetPoint(savedPoint, UIParent, savedRelPoint, CLF_Position.x, CLF_Position.y)
  end

  mainFrame:Show()
  CLF.RefreshHUD()
  return mainFrame
end

function CLF.UpdateHUD(queue)
  if not mainFrame then return end
  queue = queue or {}

  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local hud = config.hud or {}
  local spec = config.spec or {}

  -- Update status
  if statusText then
    local modeStr = CLF.combatMode == "AoE" and "AoE" or "ST"
    if CLF._modeLock then
      modeStr = modeStr .. " (locked)"
    elseif CLF._smartSwitched then
      modeStr = modeStr .. " (smart)"
    else
      modeStr = modeStr .. " (default)"
    end
    local roleStr = ""
    local effectiveTank = hud.combatRole == "tank" or (hud.combatRole == "auto" and CLF._isTankSpec)
    if effectiveTank then
      roleStr = "  |  Tank"
    end
    statusText:SetText((spec.specName or "?") .. "  |  " .. modeStr .. roleStr)
  end

  local fadeAlpha = 1
  local slot1Flash = false
  if CLF._slot1FadeStart and CLF._slot1FadeDur and CLF._slot1FadeDur > 0 then
    local fadeAge = GetTime() - CLF._slot1FadeStart
    if fadeAge < CLF._slot1FadeDur then
      slot1Flash = true
    end
  end

  -- Update icons
  if not CLF._hudSlotState then CLF._hudSlotState = {} end
  for i, frame in ipairs(iconFrames) do
    local entry = queue[i]
    if entry then
      local slotStateKey = string.lower(entry.spellName or "") .. "|" .. (entry.signalType or "") .. "|" .. tostring(entry.isGlowing or false) .. "|" .. tostring(entry.isInterrupt or false)
      local prevSlotState = CLF._hudSlotState[i]
      local slotChanged = (slotStateKey ~= prevSlotState) or (i == 1 and slot1Flash)
      CLF._hudSlotState[i] = slotStateKey
      if slotChanged then
      local texID = entry.hlIcon
      if texID and type(texID) ~= "number" then
        if type(texID) ~= "string" or not string.find(texID, "Interface", 1, true) then
          texID = nil
        end
      end
      if not texID and entry._resolvedIcon then
        local ri = entry._resolvedIcon
        if type(ri) == "number" then
          texID = ri
        elseif type(ri) == "string" and string.find(ri, "Interface", 1, true) then
          texID = ri
        end
      end
      if not texID then texID = CLF.ResolveSpellIcon(entry.spellName, entry.spellId) end
      if not texID and entry.spellIcon then
        if type(entry.spellIcon) == "number" then
          texID = entry.spellIcon
        elseif type(entry.spellIcon) == "string" then
          local numIcon = tonumber(entry.spellIcon)
          if numIcon then
            texID = numIcon
          elseif string.find(entry.spellIcon, "Interface", 1, true) then
            texID = entry.spellIcon
          elseif entry.spellIcon ~= "" and entry.spellIcon ~= "INV_Misc_QuestionMark" then
            texID = "Interface\\Icons\\" .. entry.spellIcon
          end
        end
      end
      if not texID then texID = "Interface\\Icons\\INV_Misc_QuestionMark" end
      frame.icon:SetTexture(texID)
      frame.icon:Show()
      local isCDEntry = false
      if i == 1 then
        if entry.isTrinket then
          isCDEntry = entry.cdRemaining and entry.cdRemaining > 1.5
        else
          local _, _, liveRem = CLF.SpellStatus(entry.spellName)
          local _gcdEl, _gcdDur = CLF.GetGCD()
          local gcdRem = (_gcdDur and _gcdDur > 0 and _gcdEl < _gcdDur) and (_gcdDur - _gcdEl) or 0
          isCDEntry = (liveRem and liveRem > 1.5 and liveRem > gcdRem + 0.2)
        end
      else
        isCDEntry = (entry.signalType == "cooldown") or (entry.cdRemaining and entry.cdRemaining > 1.5)
      end
      if isCDEntry then
        frame.icon:SetDesaturated(true)
        frame.icon:SetVertexColor(0.6, 0.6, 0.6, 1)
        local baseAlpha = i == 1 and 0.7 or math.max(0.1, (hud.queueOpacity or 0.6) * 0.6)
        frame:SetAlpha(i == 1 and baseAlpha * fadeAlpha or baseAlpha)
      else
        frame.icon:SetDesaturated(false)
        frame.icon:SetVertexColor(1, 1, 1, 1)
        local baseAlpha = i == 1 and 1 or math.max(0.1, (hud.queueOpacity or 0.6))
        frame:SetAlpha(i == 1 and baseAlpha * fadeAlpha or baseAlpha)
      end

      if i == 1 then
        local finalAlpha = frame:GetAlpha()
        CLF._slot1Diag = {
          spell = entry.spellName or "?",
          signal = entry.signalType or "?",
          texType = type(texID),
          texVal = type(texID) == "number" and tostring(texID) or (type(texID) == "string" and (string.sub(texID, 1, 40) or texID) or "nil"),
          isCD = isCDEntry and "Y" or "N",
          baseA = isCDEntry and 0.7 or 1,
          fadeA = fadeAlpha,
          finalA = finalAlpha,
          shown = frame:IsShown() and "Y" or "N",
          iconShown = frame.icon:IsShown() and "Y" or "N",
        }
      end
      end

      local cdStyle = hud.cooldownStyle or "sweep"
      local cdRemaining = entry.cdRemaining or 0
      local cdTotal = entry.cdTotal or 0
      if cdRemaining > 0 and cdTotal <= 0 then
        local _, _, _, tot = CLF.SpellStatus(entry.spellName, entry.spellId)
        cdTotal = tot or cdRemaining
      end

      if cooldownTexts[i] then
        if (cdStyle == "text" or cdStyle == "both") and cdRemaining > 0.2 and cdTotal > 1.5 then
          if cdRemaining >= 10 then
            cooldownTexts[i]:SetText(string.format("%.0f", cdRemaining))
          else
            cooldownTexts[i]:SetText(string.format("%.1f", cdRemaining))
          end
          local cr, cg, cb = 1, 0.5, 0.2
          if hud.cdTextColor == "yellow" then cr, cg, cb = 1, 0.9, 0.3
          elseif hud.cdTextColor == "white" then cr, cg, cb = 1, 1, 1
          elseif hud.cdTextColor == "red" then cr, cg, cb = 1, 0.2, 0.2
          elseif hud.cdTextColor == "green" then cr, cg, cb = 0.2, 1, 0.4
          end
          cooldownTexts[i]:SetTextColor(cr, cg, cb, 0.9)
          cooldownTexts[i]:Show()
        else
          cooldownTexts[i]:Hide()
        end
      end

      if i == 1 then
        local gcdActive = false
        local gcdPct = 0
        local gcdDuration = 0
        local gcdInd = hud.gcdIndicator or "both"
        local showOverlay = (gcdInd == "overlay" or gcdInd == "both")
        local showBar = (gcdInd == "bar" or gcdInd == "both")

        if gcdInd ~= "none" then
          do
            local gStart, gDur = CLF.GetGCDRaw()
            if gStart > 0 and gDur > 0 then
              local now = GetTime()
              local elapsed = now - gStart
              local remaining = gDur - elapsed
              if elapsed < gDur and remaining > 0.15 then
                gcdActive = true
                gcdPct = elapsed / gDur
                gcdDuration = gDur
              end
            end
          end
        end

        local slot1OffGCD = false
        if gcdActive and CLF._offGCDSpells and queue and queue[1] then
          local s1k = string.lower(queue[1].spellName or "")
          if CLF._offGCDSpells[s1k] then
            slot1OffGCD = true
          end
        end
        if gcdActive and not slot1OffGCD then
          if frame.gcdOverlay then
            frame.gcdOverlay:Hide()
          end
          if showBar and frame.gcdBarFill then
            local iconW = frame.icon:GetWidth()
            frame.gcdBarFill:SetWidth(math.max(1, iconW * gcdPct))
            local r, g, b = 0.15, 0.7, 0.15
            frame.gcdBarFill:SetColorTexture(r, g, b, 0.85)
            frame.gcdBarFill:Show()
            frame.gcdBarBg:Show()
          end
          CLF._gcdWasActive = true
        else
          if frame.gcdOverlay then
            frame.gcdOverlay:Hide()
          end
          if frame.gcdBarFill then
            frame.gcdBarFill:Hide()
            frame.gcdBarBg:Hide()
          end
          if CLF._gcdWasActive and frame.readyFlash then
            CLF._readyFlashStart = GetTime()
            frame.readyFlash:SetAlpha(1.0)
            frame.readyFlash:Show()
          end
          CLF._gcdWasActive = false
        end
        if frame.readyFlash and CLF._readyFlashStart then
          local elapsed = GetTime() - CLF._readyFlashStart
          if elapsed < 0.3 then
            frame.readyFlash:SetAlpha(1.0 - (elapsed / 0.3))
          else
            frame.readyFlash:Hide()
            CLF._readyFlashStart = nil
          end
        end
      end

      if cooldownSweeps[i] then
        if i == 1 then
          if sweepState[i] then sweepState[i] = nil end
          cooldownSweeps[i]:Clear()
          cooldownSweeps[i]:Hide()
        else
          local isRealCD = cdTotal > 1.5
          local showSweep = false
          local sweepStart, sweepDur

          if (cdStyle == "sweep" or cdStyle == "both") and isRealCD and cdRemaining > 0.2 then
            sweepStart = GetTime() - (cdTotal - cdRemaining)
            sweepDur = cdTotal
            showSweep = true
          end

          if showSweep and sweepStart and sweepDur then
            local prev = sweepState[i]
            if not prev or prev.start ~= sweepStart then
              sweepState[i] = { start = sweepStart, duration = sweepDur }
              cooldownSweeps[i]:SetCooldown(sweepStart, sweepDur)
              cooldownSweeps[i]:Show()
            end
          else
            if sweepState[i] then sweepState[i] = nil end
            cooldownSweeps[i]:Clear()
            cooldownSweeps[i]:Hide()
          end
        end
      end

      if entry.isInterrupt and i == 1 then
        frame:SetBackdropBorderColor(0.9, 0.2, 0.2, 1)
        if glowFrames[i] then
          glowFrames[i]:SetBackdropBorderColor(0.9, 0.2, 0.2, 0.8)
          glowFrames[i]:Show()
        end
      elseif i == 1 then
        if slot1Flash then
          frame:SetBackdropBorderColor(1, 1, 1, 1)
          if glowFrames[i] then
            glowFrames[i]:SetBackdropBorderColor(1, 1, 1, 0.9)
            glowFrames[i]:Show()
          end
        elseif entry.isGlowing then
          frame:SetBackdropBorderColor(1, 0.85, 0.2, 0.9)
          if glowFrames[i] then
            glowFrames[i]:SetBackdropBorderColor(1, 0.85, 0.2, 0.8)
            glowFrames[i]:Show()
          end
        else
          frame:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.6)
          if glowFrames[i] then
            glowFrames[i]:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], 0.4)
            glowFrames[i]:Show()
          end
        end
      else
        frame:SetBackdropBorderColor(0.3, 0.3, 0.3, 0.3)
        if glowFrames[i] then glowFrames[i]:Hide() end
      end

      -- Out of range desaturation
      if entry.inRange == false and i == 1 then
        frame.icon:SetDesaturated(true)
        frame:SetAlpha(0.4)
      else
        frame.icon:SetDesaturated(false)
      end

      -- Keybind (fade in with slot 1)
      if keybindTexts[i] and hud.showKeybind ~= false then
        local kb = entry.keybind or ""
        if kb == "" then
          kb = CLF.GetKeybind(entry.spellName) or ""
        end
        keybindTexts[i]:SetText(kb)
        if i == 1 then
          keybindTexts[i]:SetAlpha(0.85)
        end
      end

      if spellNameTexts[i] and hud.showSpellName ~= false then
        spellNameTexts[i]:SetText(entry.spellName)
        if i == 1 then
          spellNameTexts[i]:SetAlpha(0.8)
        end
      end
    else
      if CLF._hudSlotState[i] ~= nil then
        CLF._hudSlotState[i] = nil
        frame.icon:Hide()
        frame:SetBackdropBorderColor(0.15, 0.15, 0.15, 0.3)
        if keybindTexts[i] then keybindTexts[i]:SetText("") end
        if spellNameTexts[i] then spellNameTexts[i]:SetText("") end
        if cooldownTexts[i] then cooldownTexts[i]:Hide() end
        if cooldownSweeps[i] then cooldownSweeps[i]:Clear(); cooldownSweeps[i]:Hide() end
        if glowFrames[i] then glowFrames[i]:Hide() end
      end
    end
  end

  -- GCD spark update -- shows cast progress when casting, GCD sweep otherwise
  if gcdSpark and hud.showGcdSpark ~= false then
    local showSpark = false
    local pct = 0

    local cs = CLF._castState and CLF._castState.player
    if cs and cs.casting and cs.startTime then
      local castElapsed = GetTime() - cs.startTime
      local estDur = cs.duration or 1.5
      if estDur > 0 then
        pct = math.min(1, castElapsed / estDur)
        showSpark = true
      end
    end

    if not showSpark then
      local gcdElapsed, gcdDuration = CLF.GetGCD()
      if gcdDuration > 0 then
        pct = math.min(1, gcdElapsed / gcdDuration)
        showSpark = (pct < 0.95)
      end
    end

    if showSpark then
      local maxW = gcdSpark.parent:GetWidth()
      gcdSpark:SetWidth(math.max(1, maxW * pct))
      gcdSpark:Show()
      gcdSpark.parent:Show()
    else
      gcdSpark:Hide()
      gcdSpark.parent:Hide()
    end
  end

  -- Condition text
  if conditionText and hud.showCondition and queue[1] then
    conditionText:SetText(queue[1].conditionText or "")
  end

end

function CLF.ShowHUD()
  if not mainFrame then CLF.CreateHUD() end
  if mainFrame then
    mainFrame:Show()
    CLF._manualShow = true
  end
end

function CLF.HideHUD()
  if mainFrame then
    mainFrame:Hide()
    CLF._manualShow = false
  end
end

function CLF.ToggleHUD()
  if mainFrame and mainFrame:IsShown() then
    CLF.HideHUD()
  else
    CLF.ShowHUD()
  end
end

function CLF.LockHUD(lock)
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  if not config.hud then config.hud = {} end
  config.hud.lockPosition = lock
  CLF._positionLocked = lock

  if not mainFrame then CLF.CreateHUD() end
  if not mainFrame then
    print("|cFFD4A632[DMGAssist]|r Cannot toggle lock -- HUD not available")
    return
  end

  if not lock then
    mainFrame:Show()
    mainFrame:SetAlpha(config.hud.opacity or 0.95)
    CLF._manualShow = true
  else
    CLF._manualShow = false
  end

  local overlay = CLF._dragOverlay or _G["CLF_DragOverlay"]
  if overlay then
    CLF._dragOverlay = overlay
    if lock then
      overlay:Hide()
    else
      overlay:Show()
      overlay:SetAlpha(1)
      overlay:EnableMouse(true)
      overlay:SetFrameLevel(mainFrame:GetFrameLevel() + 20)
    end
  else
    print("|cFFD4A632[DMGAssist]|r Warning: drag overlay not found -- try /reload")
  end

  if lock then
    print("|cFFD4A632[DMGAssist]|r Position |cFF00FF00locked|r")
  else
    print("|cFFD4A632[DMGAssist]|r Position |cFFFFD100unlocked|r -- drag to move, right-click for options")
  end
end

function CLF.ShowDragMenu(anchor)
  local menu = CreateFrame("Frame", "CLF_DragMenu", UIParent, "UIDropDownMenuTemplate")
  UIDropDownMenu_Initialize(menu, function(self, level)
    local info = UIDropDownMenu_CreateInfo()
    info.text = "|cFFD4A632HUD Position|r"
    info.isTitle = true
    info.notCheckable = true
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Lock Position"
    info.notCheckable = true
    info.func = function() CLF.LockHUD(true) end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Hide HUD"
    info.notCheckable = true
    info.func = function()
      CLF.LockHUD(true)
      CLF.HideHUD()
    end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Cycle Mode (" .. (CLF._modeLock or CLF.combatMode or "ST") .. ")"
    info.notCheckable = true
    info.func = function() CLF.CycleMode() end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    local roleConfig = config and config.hud and config.hud.combatRole or "auto"
    local effectiveRole = roleConfig == "tank" or (roleConfig == "auto" and CLF._isTankSpec)
    local roleLabel = effectiveRole and "|cFF00FF00Tank|r" or "|cFFFFFF00DPS|r"
    if roleConfig == "auto" then
      roleLabel = roleLabel .. " (auto)"
    end
    info.text = "Toggle Role (" .. roleLabel .. ")"
    info.notCheckable = true
    info.func = function() CLF.ToggleCombatRole() end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "Open Options"
    info.notCheckable = true
    info.func = function() CLF.ToggleSettings() end
    UIDropDownMenu_AddButton(info, level)

    info = UIDropDownMenu_CreateInfo()
    info.text = "|cFF888888Cancel|r"
    info.notCheckable = true
    info.func = function() end
    UIDropDownMenu_AddButton(info, level)
  end, "MENU")
  ToggleDropDownMenu(1, nil, menu, anchor, 0, 0)
end

function CLF.UpdateConsumableBar()
  if not consumableBar then return end
  local config = CLF_Config or CLF_DefaultConfig
  if not config then return end
  local hud = config.hud or {}
  if hud.consumablesEnabled == false then
    consumableBar:Hide()
    return
  end
  if CLF._inCombat then
    consumableBar:Hide()
    return
  end
  local reminders = CLF._consumableReminder or {}
  local missingSet = {}
  for _, r in ipairs(reminders) do
    if r.status == "missing" or r.status == "expiring" then
      missingSet[r.category] = true
    end
  end

  local anyVisible = false
  local allKeys = { "flask", "food", "weaponEnh", "augmentRune" }
  for _, catKey in ipairs(allKeys) do
    local icon = consumableBar._icons[catKey]
    local lbl = consumableBar._labels[catKey]
    if icon and lbl then
      if missingSet[catKey] then
        icon:Show()
        lbl:Show()
        anyVisible = true
      else
        icon:Hide()
        lbl:Hide()
      end
    end
  end

  if anyVisible then
    consumableBar._header:Show()
    consumableBar:Show()
  else
    consumableBar._header:Hide()
    consumableBar:Hide()
  end
end

function CLF.RefreshHUD()
  if not mainFrame then return end
  CLF._hudSlotState = {}
  local hud = (CLF_Config or CLF_DefaultConfig or {}).hud or {}

  local scale = hud.scale or 1.2
  local opacity = hud.opacity or 0.95
  local bgAlpha = hud.bgOpacity or 0.75
  local borderStyle = hud.borderStyle or "thin"
  local edgeSize = borderStyle == "thick" and 2 or (borderStyle == "none" and 0 or 1)
  local borderAlpha = borderStyle == "none" and 0 or (hud.borderOpacity or 0.25)

  local oldScale = mainFrame:GetScale()
  if issecretvalue and issecretvalue(oldScale) then oldScale = 1 end
  local cx, cy
  if oldScale and oldScale > 0 then
    local gOk, l, b, w, h = pcall(mainFrame.GetRect, mainFrame)
    if gOk and l and b and w and h then
      local lOk = type(l) == "number" and not (issecretvalue and issecretvalue(l))
      local bOk = type(b) == "number" and not (issecretvalue and issecretvalue(b))
      local wOk = type(w) == "number" and not (issecretvalue and issecretvalue(w))
      local hOk = type(h) == "number" and not (issecretvalue and issecretvalue(h))
      if lOk and bOk and wOk and hOk then
        cx = (l + w / 2) * oldScale
        cy = (b + h / 2) * oldScale
      end
    end
  end

  mainFrame:SetAlpha(opacity)
  mainFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = math.max(edgeSize, 1),
  })
  mainFrame:SetBackdropColor(0.05, 0.05, 0.08, bgAlpha)
  mainFrame:SetBackdropBorderColor(GOLD[1], GOLD[2], GOLD[3], borderAlpha)

  local iconSize = hud.iconSize or 48
  local predSize = hud.predIconSize or 34
  local padding = hud.framePadding or 16
  local spacing = hud.iconSpacing or 14
  local queueSlots = mathMin(hud.queueSlots or 3, 3)

  local totalWidth = iconSize + padding * 2
  if queueSlots > 1 then
    totalWidth = totalWidth + (queueSlots - 1) * (predSize + spacing)
  end
  local minWidth = hud.minFrameWidth or 220
  if totalWidth < minWidth then totalWidth = minWidth end
  local totalHeight = iconSize + padding * 2 + 40
  mainFrame:SetSize(totalWidth, totalHeight)

  if statusText then
    local hFS = hud.headerFontSize or 11
    statusText:SetFont("Fonts\\FRIZQT__.TTF", hFS, "OUTLINE")
    local htcName = hud.headerTextColor or "Gold"
    local htR, htG, htB = GOLD[1], GOLD[2], GOLD[3]
    if htcName == "White" then htR, htG, htB = 1, 1, 1
    elseif htcName == "Class" then htR, htG, htB = CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3]
    elseif htcName == "Green" then htR, htG, htB = 0.3, 1, 0.3
    elseif htcName == "Cyan" then htR, htG, htB = 0.3, 0.9, 1 end
    statusText:SetTextColor(htR, htG, htB, 0.6)
  end

  if consumableBar then
    consumableBar:SetSize(totalWidth, 68)
    consumableBar:ClearAllPoints()
    consumableBar:SetPoint("TOP", mainFrame, "BOTTOM", 0, -4)
    local chFS = hud.headerFontSize or 11
    local ccFS = hud.consumablesFontSize or 11
    local ccLabelFS = math.max(8, ccFS - 1)
    if consumableBar._header then
      consumableBar._header:ClearAllPoints()
      consumableBar._header:SetPoint("TOPLEFT", consumableBar, "TOPLEFT", padding, 0)
      consumableBar._header:SetFont("Fonts\\FRIZQT__.TTF", ccFS, "OUTLINE")
      local hdrColorName = hud.headerTextColor or "Gold"
      local hdrR, hdrG, hdrB = GOLD[1], GOLD[2], GOLD[3]
      if hdrColorName == "White" then hdrR, hdrG, hdrB = 1, 1, 1
      elseif hdrColorName == "Class" then hdrR, hdrG, hdrB = CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3]
      elseif hdrColorName == "Green" then hdrR, hdrG, hdrB = 0.3, 1, 0.3
      elseif hdrColorName == "Cyan" then hdrR, hdrG, hdrB = 0.3, 0.9, 1 end
      consumableBar._header:SetTextColor(hdrR, hdrG, hdrB, 0.7)
    end
    for rowIdx, row in ipairs(consumableBar._rows or {}) do
      local yOff = -24 - (rowIdx - 1) * 20
      for colIdx, catKey in ipairs(row) do
        local xOff = padding + (colIdx - 1) * (totalWidth * 0.5)
        local icon = consumableBar._icons[catKey]
        if icon then
          icon:ClearAllPoints()
          icon:SetPoint("TOPLEFT", consumableBar, "TOPLEFT", xOff, yOff)
        end
        local lbl = consumableBar._labels[catKey]
        if lbl then
          lbl:SetFont("Fonts\\FRIZQT__.TTF", ccLabelFS, "OUTLINE")
          local cColorName = hud.headerTextColor or "Gold"
          local cR, cG, cB = GOLD[1], GOLD[2], GOLD[3]
          if cColorName == "White" then cR, cG, cB = 1, 1, 1
          elseif cColorName == "Class" then cR, cG, cB = CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3]
          elseif cColorName == "Green" then cR, cG, cB = 0.3, 1, 0.3
          elseif cColorName == "Cyan" then cR, cG, cB = 0.3, 0.9, 1 end
          lbl:SetTextColor(cR, cG, cB, 0.7)
        end
      end
    end
  end

  mainFrame:SetScale(scale)

  if CLF_Position and CLF_Position.x then
    mainFrame:ClearAllPoints()
    local savedPoint = CLF_Position.point or "BOTTOMLEFT"
    local savedRelPoint = CLF_Position.relPoint or "BOTTOMLEFT"
    mainFrame:SetPoint(savedPoint, UIParent, savedRelPoint, CLF_Position.x, CLF_Position.y)
  elseif cx and cy then
    mainFrame:ClearAllPoints()
    mainFrame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
  end

  for i, frame in ipairs(iconFrames) do
    if i <= queueSlots then
      local size = (i == 1) and iconSize or predSize
      frame:SetSize(size, size)
      frame:ClearAllPoints()
      if i == 1 then
        frame:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", padding, padding + 20)
      else
        frame:SetPoint("LEFT", iconFrames[i - 1], "RIGHT", spacing, 0)
      end
      if glowFrames[i] then
        glowFrames[i]:SetSize(size + 8, size + 8)
      end
      if spellNameTexts[i] then
        local snPad = hud.spellNamePadding or 6
        spellNameTexts[i]:ClearAllPoints()
        spellNameTexts[i]:SetPoint("TOP", frame, "BOTTOM", 0, -snPad)
        spellNameTexts[i]:SetWidth(size + 8)
        local fontSize = (i == 1) and (hud.spellNameFontSize or 10) or math.max(7, (hud.spellNameFontSize or 10) - 1)
        spellNameTexts[i]:SetFont("Fonts\\FRIZQT__.TTF", fontSize, "OUTLINE")
      end
      frame:Show()
    else
      frame:Hide()
    end
  end

  -- Keybind text: font, color, position, visibility
  for i, frame in ipairs(iconFrames) do
    if keybindTexts[i] then
      if hud.showKeybind == false then
        keybindTexts[i]:Hide()
      else
        keybindTexts[i]:Show()
        local kbSize = (i == 1) and (hud.keybindFontSize or 11) or math.max(7, (hud.keybindFontSize or 11) - 2)
        keybindTexts[i]:SetFont("Fonts\\FRIZQT__.TTF", kbSize, "OUTLINE")
        local kbColor = hud.keybindColor or "White"
        if kbColor == "Gold" then
          keybindTexts[i]:SetTextColor(0.83, 0.65, 0.2, 0.85)
        elseif kbColor == "Class" then
          keybindTexts[i]:SetTextColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 0.85)
        elseif kbColor == "Green" then
          keybindTexts[i]:SetTextColor(0.3, 1, 0.3, 0.85)
        elseif kbColor == "Cyan" then
          keybindTexts[i]:SetTextColor(0.3, 0.9, 1, 0.85)
        else
          keybindTexts[i]:SetTextColor(1, 1, 1, 0.85)
        end
        keybindTexts[i]:ClearAllPoints()
        local pos = hud.keybindPosition or "bottom-right"
        if pos == "bottom-right" then
          keybindTexts[i]:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 2, -2)
        elseif pos == "top-right" then
          keybindTexts[i]:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 2, 2)
        elseif pos == "top-left" then
          keybindTexts[i]:SetPoint("TOPLEFT", frame, "TOPLEFT", -2, 2)
        elseif pos == "bottom-left" then
          keybindTexts[i]:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", -2, -2)
        elseif pos == "center" then
          keybindTexts[i]:SetPoint("CENTER")
        end
      end
    end

    -- Spell name text: font, visibility
    if spellNameTexts[i] then
      if hud.showSpellName == false then
        spellNameTexts[i]:Hide()
      else
        spellNameTexts[i]:Show()
        local snSize = (i == 1) and (hud.spellNameFontSize or 10) or math.max(7, (hud.spellNameFontSize or 10) - 1)
        spellNameTexts[i]:SetFont("Fonts\\FRIZQT__.TTF", snSize, "OUTLINE")
      end
    end

    -- Cooldown display visibility based on style
    local cdStyle = hud.cooldownStyle or "sweep"
    if cooldownTexts[i] then
      if cdStyle == "text" or cdStyle == "both" then
        cooldownTexts[i]:Show()
        local sz = (i == 1) and (hud.cdTextSize or 14) or math.max(7, (hud.cdTextSize or 14) - 4)
        cooldownTexts[i]:SetFont("Fonts\\FRIZQT__.TTF", sz, "OUTLINE")
        cooldownTexts[i]:ClearAllPoints()
        cooldownTexts[i]:SetPoint(hud.cdTextPosition or "CENTER", iconFrames[i], hud.cdTextPosition or "CENTER", hud.cdTextOffsetX or 0, hud.cdTextOffsetY or 0)
      else
        cooldownTexts[i]:Hide()
      end
    end
    if cooldownSweeps[i] then
      if cdStyle == "sweep" or cdStyle == "both" then
        cooldownSweeps[i]:SetAllPoints(iconFrames[i].icon or iconFrames[i])
      else
        cooldownSweeps[i]:Clear()
        cooldownSweeps[i]:Hide()
      end
    end

    -- Queue labels (NOW/NEXT) visibility
    if queueLabels[i] then
      if hud.showQueueLabels == false then
        queueLabels[i]:Hide()
      else
        queueLabels[i]:Show()
      end
    end
  end

  -- Header (status text + gear button) visibility
  if statusText then
    if hud.showHeader == false then
      statusText:Hide()
    else
      statusText:Show()
    end
  end
  local gearBtn = _G["CLF_GearBtn"]
  if gearBtn then
    if hud.showHeader == false then
      gearBtn:Hide()
    else
      gearBtn:Show()
    end
  end

  -- GCD spark visibility + sizing
  if gcdSpark then
    gcdSpark:SetSize(iconSize, 3)
    if hud.showGcdSpark == false then
      gcdSpark.parent:Hide()
    else
      gcdSpark.parent:Show()
    end
  end

  -- Condition text visibility
  if conditionText then
    if hud.showCondition == false or not hud.showCondition then
      conditionText:Hide()
    else
      conditionText:Show()
    end
  end

end

function CLF.ShowAssistedWarning()
  if CLF._assistedWarningFrame then
    CLF._assistedWarningFrame:Show()
    return
  end

  local wf = CreateFrame("Frame", "CLF_AssistedWarning", UIParent, "BackdropTemplate")
  wf:SetSize(420, 180)
  wf:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
  wf:SetFrameStrata("DIALOG")
  wf:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 2,
  })
  wf:SetBackdropColor(0.08, 0.06, 0.04, 0.95)
  wf:SetBackdropBorderColor(0.83, 0.45, 0.1, 0.9)

  local title = wf:CreateFontString(nil, "OVERLAY")
  title:SetFont("Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  title:SetPoint("TOP", wf, "TOP", 0, -14)
  title:SetTextColor(1, 0.6, 0.1, 1)
  title:SetText("|cFFD4A632[DMGAssist]|r Assisted Combat Required")

  local body = wf:CreateFontString(nil, "OVERLAY")
  body:SetFont("Fonts\\FRIZQT__.TTF", 11, "")
  body:SetPoint("TOP", title, "BOTTOM", 0, -12)
  body:SetWidth(380)
  body:SetJustifyH("CENTER")
  body:SetTextColor(0.9, 0.9, 0.9, 1)
  body:SetText("DMGAssist needs the Assisted Combat Highlights\nfeature to work properly.\n\nEnable it in:\n|cFF00FF00Options (Esc)|r > |cFF00FF00Gameplay|r > |cFF00FF00Combat|r\n> |cFFFFD100Assisted Combat Highlight Spells|r\n\nSet it to |cFF00FF00Always|r or |cFF00FF00In Combat|r.")

  local dismiss = CreateFrame("Button", nil, wf, "BackdropTemplate")
  dismiss:SetSize(120, 28)
  dismiss:SetPoint("BOTTOM", wf, "BOTTOM", 0, 14)
  dismiss:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  dismiss:SetBackdropColor(0.2, 0.15, 0.08, 0.9)
  dismiss:SetBackdropBorderColor(0.83, 0.65, 0.2, 0.7)
  local dismissText = dismiss:CreateFontString(nil, "OVERLAY")
  dismissText:SetFont("Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
  dismissText:SetPoint("CENTER")
  dismissText:SetTextColor(0.83, 0.65, 0.2, 1)
  dismissText:SetText("Dismiss")
  dismiss:SetScript("OnClick", function()
    wf:Hide()
    CLF._assistedDismissed = true
    CLF._assistedWarningShown = true
  end)
  dismiss:SetScript("OnEnter", function(self)
    self:SetBackdropColor(0.3, 0.22, 0.1, 0.95)
  end)
  dismiss:SetScript("OnLeave", function(self)
    self:SetBackdropColor(0.2, 0.15, 0.08, 0.9)
  end)

  CLF._assistedWarningFrame = wf
  wf:Show()
end
