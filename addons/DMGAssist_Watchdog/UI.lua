-- UI.lua: a small viewer. One scrollable text box shows either the summary or
-- the report string (pre-selected, so Ctrl+C copies it for pasting into the chat). Created lazily, never
-- in combat-critical code.

local _, ns = ...
local U = ns.U

local V = {}
ns.UI = V

local frame, editBox

local function TryCreate(frameType, name, parent, template)
  local ok, f = pcall(CreateFrame, frameType, name, parent, template)
  if ok and f then
    return f
  end
  return CreateFrame(frameType, name, parent)
end

local function Button(parent, label, width, onClick)
  local b = TryCreate("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width, 22)
  b:SetText(label)
  b:SetScript("OnClick", onClick)
  return b
end

local function Build()
  frame = TryCreate("Frame", "DMGAssistWatchdogFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(720, 460)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "DMGAssistWatchdogFrame") -- Escape closes it

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -6)
  title:SetText("DMGAssist Watchdog " .. ns.VERSION)

  local scroll = TryCreate("ScrollFrame", "DMGAssistWatchdogScroll", frame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 14, -32)
  scroll:SetPoint("BOTTOMRIGHT", -34, 44)

  editBox = CreateFrame("EditBox", nil, scroll)
  editBox:SetMultiLine(true)
  editBox:SetAutoFocus(false)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetWidth(660)
  editBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  scroll:SetScrollChild(editBox)

  local x = 14
  local function place(b)
    b:SetPoint("BOTTOMLEFT", x, 12)
    x = x + b:GetWidth() + 6
  end
  place(Button(frame, "Copy report", 110, function()
    V.ShowExport("last")
  end))
  place(Button(frame, "Copy everything", 130, function()
    V.ShowExport("all")
  end))
  place(Button(frame, "Summary", 90, function()
    V.ShowSummary()
  end))
  place(Button(frame, "Run probe", 100, function()
    if InCombatLockdown() then
      U.Print("Probe from the button only out of combat; in combat it runs automatically.")
      return
    end
    local ok, err = pcall(ns.Probe.Run, "manual")
    if not ok then
      ns.Errors.Record("probe", err)
    end
    V.ShowSummary()
  end))
end

local function SetText(text, select)
  if not frame then
    Build()
  end
  frame:Show()
  editBox:SetText(text)
  editBox:SetCursorPosition(0)
  if select then
    editBox:SetFocus()
    editBox:HighlightText()
  end
end

function V.ShowSummary()
  SetText(ns.Export.Summary(), false)
end

function V.ShowExport(scope)
  local str, fmt, len = ns.Export.Encode(scope)
  if not str then
    SetText("Export failed: " .. tostring(fmt), false)
    return
  end
  U.Print("Report ready (%d characters, already selected): press Ctrl+C, then paste it into the chat.", len)
  SetText(str, true)
end

-- /dmgw opens straight to the report, selected, ready for Ctrl+C.
function V.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    V.ShowExport("last")
  end
end
