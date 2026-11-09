-- UI.lua: the "Report an issue" window, in three steps:
--   1. Two boxes for your own words: what went wrong (and what you expected), and what you were doing.
--   2. The report, already selected: Ctrl+C copies your words and the report together, as one paste.
--   3. A link to the issue page on GitHub (click it, Ctrl+C, open it in a browser, paste with Ctrl+V).
-- Your words are kept (in the saved variables) until you clear them, so closing the window loses nothing, and
-- they also go inside the encoded report. Created lazily, never in combat-critical code.
--
-- The report box is checked after filling: if it holds less than the text (an edit box can cap its text), the
-- report is rebuilt smaller until it fits, so a half string is never copied. Any failure is shown in the box
-- itself, never leaving older text behind that could be copied by mistake.

local _, ns = ...
local U = ns.U

local V = {}
ns.UI = V

V.ISSUES = "https://github.com/zonearc/dmgassistwow/issues/new?template=bug_report.yml"

local frame, editBox, status, whatBox, doingBox, linkBox

-- Text in the player's language: DMGAssist's translations, when DMGAssist is loaded (it always is by the time
-- this window opens). The copied report itself stays in English, so anyone can read it.
local function T(s)
  local api = _G.DMGAssistAPI
  local L = type(api) == "table" and api.L
  return L and L[s] or s
end
local filling = false

local function TryCreate(frameType, name, parent, template)
  local ok, f = pcall(CreateFrame, frameType, name, parent, template)
  if ok and f then
    return f
  end
  return CreateFrame(frameType, name, parent)
end

local function Label(text, anchor, y, template)
  local fs = frame:CreateFontString(nil, "OVERLAY", template or "GameFontNormal")
  if anchor then
    fs:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -10)
  else
    fs:SetPoint("TOPLEFT", 16, y or -32)
  end
  fs:SetJustifyH("LEFT")
  fs:SetText(T(text))
  return fs
end

-- A box with a dark background behind it (edit boxes have none of their own when multi-line).
local function Boxed(height, anchor, y)
  local bg = TryCreate("Frame", nil, frame, "BackdropTemplate")
  bg:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, y or -4)
  bg:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
  bg:SetHeight(height)
  if bg.SetBackdrop then
    pcall(bg.SetBackdrop, bg, { bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 } })
    pcall(bg.SetBackdropColor, bg, 0, 0, 0, 0.6)
    pcall(bg.SetBackdropBorderColor, bg, 0.5, 0.5, 0.5, 1)
  end
  return bg
end

local function Notes()
  local db = ns.db
  if not db then
    return {}
  end
  db.reportNote = type(db.reportNote) == "table" and db.reportNote or {}
  return db.reportNote
end

local function Clean(s)
  s = type(s) == "string" and s or ""
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Your words, ahead of the report string, so a pasted issue reads well before anyone decodes anything.
function V.Header()
  local n = Notes()
  local what, doing = Clean(n.what), Clean(n.doing)
  if what == "" and doing == "" then
    return ""
  end
  local lines = {}
  if what ~= "" then
    lines[#lines + 1] = "What went wrong: " .. what
  end
  if doing ~= "" then
    lines[#lines + 1] = "What I was doing: " .. doing
  end
  return table.concat(lines, "\n") .. "\n\n"
end

-- Typing changes the report: rebuild it shortly after the last key, not on every key.
local pending = 0
local function NoteChanged(key, box)
  if filling then
    return
  end
  Notes()[key] = box:GetText()
  pending = pending + 1
  local mine = pending
  if C_Timer and C_Timer.After then
    C_Timer.After(0.6, function()
      if mine == pending and frame and frame:IsShown() then
        V.ShowReport(true)
      end
    end)
  end
end

local function NoteBox(parent, key, multi)
  local box = CreateFrame("EditBox", nil, parent)
  box:SetMultiLine(multi)
  box:SetAutoFocus(false)
  box:SetFontObject(ChatFontNormal)
  box:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -6)
  box:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 6)
  box:SetWidth(660)
  pcall(box.SetMaxLetters, box, 600)
  box:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  box:SetScript("OnTabPressed", function(self)
    self:ClearFocus()
  end)
  if not multi then
    box:SetScript("OnEnterPressed", function(self)
      self:ClearFocus()
    end)
  end
  box:SetScript("OnTextChanged", function(self, user)
    if user then
      NoteChanged(key, self)
    end
  end)
  -- Clicking anywhere in the dark box puts the cursor in it.
  if parent.EnableMouse then
    parent:EnableMouse(true)
    parent:SetScript("OnMouseDown", function()
      box:SetFocus()
    end)
  end
  return box
end

local function Build()
  frame = TryCreate("Frame", "DMGAssistWatchdogFrame", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(720, 560)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  tinsert(UISpecialFrames, "DMGAssistWatchdogFrame") -- Escape closes it
  -- The template's X did not close the window in game (2026-11-08): close it ourselves.
  local close = frame.CloseButton or _G["DMGAssistWatchdogFrameCloseButton"]
  if close and close.SetScript then
    close:SetScript("OnClick", function()
      frame:Hide()
    end)
  end

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -6)
  title:SetText(T("DMGAssist: Report an issue or give feedback"))

  -- Step 1: your words.
  local step1 = Label("|cffffd100Step 1.|r What went wrong? What did you expect instead?", nil, -34)
  local whatBg = Boxed(58, step1)
  whatBox = NoteBox(whatBg, "what", true)
  local doingLabel = Label("What were you doing? (for example: 5 dummies, a Mythic+ pull, a raid boss, solo)",
    whatBg, -8, "GameFontNormalSmall")
  local doingBg = Boxed(28, doingLabel)
  doingBox = NoteBox(doingBg, "doing", false)
  local clear = TryCreate("Button", nil, frame, "UIPanelButtonTemplate")
  clear:SetSize(90, 20)
  clear:SetText(T("Clear"))
  clear:SetPoint("BOTTOMRIGHT", doingBg, "TOPRIGHT", 0, 2)
  clear:SetScript("OnClick", function()
    local n = Notes()
    n.what, n.doing = nil, nil
    filling = true
    whatBox:SetText("")
    doingBox:SetText("")
    filling = false
    V.ShowReport()
  end)

  -- Step 2: the report.
  local step2 = Label("|cffffd100Step 2.|r Click the box below and press |cffffffffCtrl+C|r. "
    .. "Your words above are included.", doingBg, -12)
  local reportBg = Boxed(220, step2)
  local scroll = TryCreate("ScrollFrame", "DMGAssistWatchdogScroll", reportBg, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -6)
  scroll:SetPoint("BOTTOMRIGHT", -28, 6)

  -- Step 3: where to paste it.
  local step3 = Label("|cffffd100Step 3.|r Open this page in your browser (click it, Ctrl+C, paste it in the "
    .. "address bar),", reportBg, -12)
  local step3b = Label("then paste your report with |cffffffffCtrl+V|r and press Create. A screenshot helps too.",
    step3, -4)
  local linkBg = Boxed(28, step3b)
  linkBox = CreateFrame("EditBox", nil, linkBg)
  linkBox:SetAutoFocus(false)
  linkBox:SetFontObject(ChatFontNormal)
  linkBox:SetPoint("TOPLEFT", linkBg, "TOPLEFT", 8, -6)
  linkBox:SetPoint("BOTTOMRIGHT", linkBg, "BOTTOMRIGHT", -8, 6)
  linkBox:SetText(V.ISSUES)
  linkBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  linkBox:SetScript("OnEditFocusGained", function(self)
    self:HighlightText()
  end)
  linkBox:SetScript("OnMouseUp", function(self)
    self:SetFocus()
    self:HighlightText()
  end)
  linkBox:SetScript("OnTextChanged", function(self, user)
    if user then
      self:SetText(V.ISSUES) -- read only
      self:HighlightText()
    end
  end)

  -- The report box itself (made last: it is the one that is filled and read back).
  editBox = CreateFrame("EditBox", nil, scroll)
  editBox:SetMultiLine(true)
  editBox:SetAutoFocus(false)
  editBox:SetFontObject(ChatFontNormal)
  editBox:SetWidth(630)
  -- No length cap of our own (0 = none); the readback below catches any cap the game applies anyway.
  pcall(editBox.SetMaxLetters, editBox, 0)
  pcall(editBox.SetMaxBytes, editBox, 0)
  editBox:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
  end)
  -- Clicking the box (or it getting focus back) selects everything again, so Ctrl+C always copies all of it.
  editBox:SetScript("OnEditFocusGained", function(self)
    self:HighlightText()
  end)
  editBox:SetScript("OnMouseUp", function(self)
    self:SetFocus()
    self:HighlightText()
  end)
  scroll:SetScrollChild(editBox)

  local button = TryCreate("Button", nil, frame, "UIPanelButtonTemplate")
  button:SetSize(140, 22)
  button:SetText(T("Refresh report")) -- addons can't write to the clipboard: this rebuilds and selects it
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
  filling = true
  local n = Notes()
  if whatBox and not whatBox:HasFocus() then
    whatBox:SetText(n.what or "")
  end
  if doingBox and not doingBox:HasFocus() then
    doingBox:SetText(n.doing or "")
  end
  filling = false
  editBox:SetText("")
  editBox:SetText(text)
  editBox:SetCursorPosition(0)
  if select then
    editBox:SetFocus()
    editBox:HighlightText()
    -- A menu that opened this window (the minimap menu) takes keyboard focus back when it closes, which leaves
    -- the text looking selected while Ctrl+C goes nowhere. Take focus again on the next frame.
    if C_Timer and C_Timer.After then
      C_Timer.After(0, function()
        if frame:IsShown() and not (whatBox:HasFocus() or doingBox:HasFocus()) then
          editBox:SetFocus()
          editBox:HighlightText()
        end
      end)
    end
  end
  status:SetText(note or "")
end

-- Build the report and put it in the box; smaller if the box would cut it. `typing`: rebuilt because the
-- player is writing in step 1, so the cursor stays where they are.
function V.ShowReport(typing)
  local limit = ns.Export.REPORT_LIMIT
  for _ = 1, 4 do
    local ok, str, fmt, len = pcall(ns.Export.Encode)
    if not ok or not str then
      local why = ok and tostring(fmt) or tostring(str)
      ns.Errors.Record("watchdog_internal", "report failed: " .. why)
      Fill(T("The report could not be built:") .. " " .. why, false, T("Report failed"))
      return false
    end
    local text = V.Header() .. str
    -- The report's time is shown, so a paste can be matched to the report (a stale clipboard is easy to spot).
    local stamp = date("%H:%M:%S")
    Fill(text, not typing, string.format(T(typing and "Report %s, %d characters" or
      "Report %s, %d characters, selected: press Ctrl+C to copy it."), stamp, len))
    local held = editBox:GetText()
    if type(held) == "string" and #held == #text then
      if not typing then
        U.Print("Report %s ready (%d characters, already selected): press Ctrl+C, then paste it into a new issue.",
          stamp, len)
      end
      ns.Export.REPORT_LIMIT = limit
      return true
    end
    -- The box kept only part of it: rebuild smaller.
    ns.Export.REPORT_LIMIT = math.floor(math.min(ns.Export.REPORT_LIMIT, #(held or "")) * 0.8)
  end
  ns.Export.REPORT_LIMIT = limit
  Fill(T("The report did not fit in the window. Type /dmgw status and paste what it prints instead."), false,
    T("Report too large"))
  return false
end

-- Readable overview (/dmgw status prints it to chat; not part of the panel any more).
function V.ShowSummary()
  Fill(ns.Export.Summary(), false, T("Summary (for reading; the report is what to paste)"))
end

-- /dmgw opens straight to the report, selected, ready for Ctrl+C.
function V.Toggle()
  if frame and frame:IsShown() then
    frame:Hide()
  else
    V.ShowReport()
  end
end
