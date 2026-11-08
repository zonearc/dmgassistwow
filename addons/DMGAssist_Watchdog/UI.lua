-- UI.lua: the report window. One button, one text box: the report is built, put in the box already
-- selected, and Ctrl+C copies it for pasting into the chat. Created lazily, never in combat-critical code.
--
-- The box is checked after filling: if it holds less than the report (an edit box can cap its text), the
-- report is rebuilt smaller until it fits, so a half string is never copied. Any failure is shown in the box
-- itself, never leaving older text behind that could be copied by mistake.

local _, ns = ...
local U = ns.U

local V = {}
ns.UI = V

local frame, editBox, status

local function TryCreate(frameType, name, parent, template)
  local ok, f = pcall(CreateFrame, frameType, name, parent, template)
  if ok and f then
    return f
  end
  return CreateFrame(frameType, name, parent)
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
  -- No length cap of our own (0 = none); the readback below catches any cap the game applies anyway.
  pcall(editBox.SetMaxLetters, editBox, 0)
  pcall(editBox.SetMaxBytes, editBox, 0)
  editBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  scroll:SetScrollChild(editBox)

  local button = TryCreate("Button", nil, frame, "UIPanelButtonTemplate")
  button:SetSize(140, 22)
  button:SetText("Copy report")
  button:SetScript("OnClick", function()
    V.ShowReport()
  end)
  button:SetPoint("BOTTOMLEFT", 14, 12)

  status = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("LEFT", button, "RIGHT", 10, 0)
end

local function Fill(text, select, note)
  if not frame then
    Build()
  end
  frame:Show()
  editBox:SetText("")
  editBox:SetText(text)
  editBox:SetCursorPosition(0)
  if select then
    editBox:SetFocus()
    editBox:HighlightText()
  end
  status:SetText(note or "")
end

-- Build the report and put it in the box; smaller if the box would cut it.
function V.ShowReport()
  local limit = ns.Export.REPORT_LIMIT
  for _ = 1, 4 do
    local ok, str, fmt, len = pcall(ns.Export.Encode)
    if not ok or not str then
      local why = ok and tostring(fmt) or tostring(str)
      ns.Errors.Record("watchdog_internal", "report failed: " .. why)
      Fill("The report could not be built: " .. why, false, "Report failed")
      return false
    end
    Fill(str, true, string.format("%d characters, selected: press Ctrl+C, then paste into the chat.", len))
    local held = editBox:GetText()
    if type(held) == "string" and #held == #str then
      U.Print("Report ready (%d characters, already selected): press Ctrl+C, then paste it into the chat.", len)
      ns.Export.REPORT_LIMIT = limit
      return true
    end
    -- The box kept only part of it: rebuild smaller.
    ns.Export.REPORT_LIMIT = math.floor(math.min(ns.Export.REPORT_LIMIT, #(held or "")) * 0.8)
  end
  ns.Export.REPORT_LIMIT = limit
  Fill("The report did not fit in the window. Type /dmgw status and paste what it prints instead.", false,
    "Report too large")
  return false
end

-- Readable overview (/dmgw status prints it to chat; not part of the panel any more).
function V.ShowSummary()
  Fill(ns.Export.Summary(), false, "Summary (for reading; the report is what to paste)")
end

-- /dmgw opens straight to the report, selected, ready for Ctrl+C.
function V.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    V.ShowReport()
  end
end
