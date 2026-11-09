-- Welcome.lua: three questions the first time DMGAssist runs (per settings profile, so alts sharing the Default
-- profile are asked once): where the HUD goes, how big, and when it shows. Each has a suggested answer; "Use the
-- suggestions" answers all three at once. Asked again with /dmga welcome or the button on the main settings page.
-- Players who had already placed the HUD before this existed are not asked.

local _, ns = ...
local U, L = ns.U, ns.L

local W = {}
ns.Welcome = W

local function Hud()
  ns.db.hud = type(ns.db.hud) == "table" and ns.db.hud or {}
  return ns.db.hud
end

local function Place(point)
  ns.db.point = point
  local f = ns.Display.frame
  if f then
    f:ClearAllPoints()
    f:SetPoint(point[1], UIParent, point[2], point[3], point[4])
  end
end

-- Just above the main action bar (wherever the player's UI puts it), else a sensible spot low in the middle.
function W.AboveBars()
  local bar = _G.MainActionBar or _G.MainMenuBar
  local top = bar and U.Get(bar.GetTop, bar)
  local scale = bar and U.Get(bar.GetEffectiveScale, bar) or 1
  local uiScale = U.Get(UIParent.GetEffectiveScale, UIParent) or 1
  local y = type(top) == "number" and (top * scale / uiScale + 90) or 260
  return { "BOTTOM", "BOTTOM", 0, math.floor(y) }
end

local function OpenEditMode()
  local em = _G.EditModeManagerFrame
  if em and not ns.State.combatStart and ShowUIPanel then
    local ok = pcall(ShowUIPanel, em)
    if ok then
      return true
    end
  end
  ns.db.locked = false
  ns.Display.SetLocked(false)
  U.Print("%s", L["The HUD is unlocked: drag it where you like, then lock it in Settings > DMGAssist."])
  return false
end

W.QUESTIONS = {
  { text = "Where should the recommendations go?",
    options = {
      { "Just above my action bars", function()
        Place(W.AboveBars())
      end },
      { "Middle of the screen, below my character", function()
        Place({ "CENTER", "CENTER", 0, -150 })
      end },
      { "I'll place it myself (Edit Mode)", function()
        W.afterwards = OpenEditMode
      end },
    } },
  { text = "How big?",
    options = {
      { "Medium", function()
        Hud().scale = 1.0
      end },
      { "Small", function()
        Hud().scale = 0.8
      end },
      { "Large", function()
        Hud().scale = 1.3
      end },
    } },
  { text = "When should it show?",
    options = {
      { "In combat, and when I target an enemy", function()
        Hud().hideOutOfCombat, Hud().showWithTarget = true, true
      end },
      { "Only in combat", function()
        Hud().hideOutOfCombat, Hud().showWithTarget = true, false
      end },
      { "Always", function()
        Hud().hideOutOfCombat = false
      end },
    } },
}

local frame, step

local function Finish()
  ns.db.welcomed = true
  frame:Hide()
  ns.Display.Rebuild()
  U.Print("%s", L["All set. Change any of it in Settings > DMGAssist (or /dmga), or move the HUD in Edit Mode."])
  local after = W.afterwards
  W.afterwards = nil
  if after then
    after()
  end
end

local function Show(i)
  step = i
  local q = W.QUESTIONS[i]
  frame.count:SetText(string.format(L["Question %d of %d"], i, #W.QUESTIONS))
  frame.question:SetText(L[q.text])
  for n, button in ipairs(frame.buttons) do
    local o = q.options[n]
    if o then
      button:SetText(n == 1 and (L[o[1]] .. "  |cff88ff88" .. L["(suggested)"] .. "|r") or L[o[1]])
      button:Show()
    else
      button:Hide()
    end
  end
  frame.back:SetShown(i > 1)
end

local function Answer(n)
  local o = W.QUESTIONS[step].options[n]
  if o then
    o[2]()
  end
  if step < #W.QUESTIONS then
    Show(step + 1)
  else
    Finish()
  end
end

local function Build()
  frame = CreateFrame("Frame", "DMGAssistWelcome", UIParent, "BasicFrameTemplateWithInset")
  frame:SetSize(460, 260)
  frame:SetPoint("CENTER", 0, 80)
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  title:SetPoint("TOP", 0, -6)
  title:SetText(L["Welcome to DMGAssist"])
  frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  frame.count:SetPoint("TOPLEFT", 18, -34)
  frame.question = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  frame.question:SetPoint("TOPLEFT", frame.count, "BOTTOMLEFT", 0, -8)
  frame.question:SetWidth(420)
  frame.question:SetJustifyH("LEFT")
  frame.buttons = {}
  local anchor = frame.question
  for n = 1, 3 do
    local b = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    b:SetSize(420, 28)
    b:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, n == 1 and -14 or -6)
    b:SetScript("OnClick", function()
      Answer(n)
    end)
    frame.buttons[n] = b
    anchor = b
  end
  local skip = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  skip:SetSize(200, 22)
  skip:SetPoint("BOTTOMRIGHT", -14, 12)
  skip:SetText(L["Use the suggestions"])
  skip:SetScript("OnClick", function()
    for i = step, #W.QUESTIONS do
      W.QUESTIONS[i].options[1][2]()
    end
    Finish()
  end)
  frame.back = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.back:SetSize(80, 22)
  frame.back:SetPoint("BOTTOMLEFT", 14, 12)
  frame.back:SetText(L["Back"])
  frame.back:SetScript("OnClick", function()
    Show(math.max(1, step - 1))
  end)
  local close = frame.CloseButton
  if close and close.SetScript then
    close:SetScript("OnClick", function()
      ns.db.welcomed = true -- closed: don't ask again (the button in Settings brings it back)
      frame:Hide()
    end)
  end
end

function W.Open()
  if not ns.db then
    return
  end
  if not frame then
    Build()
  end
  W.afterwards = nil
  Show(1)
  frame:Show()
end

-- At login: ask once per profile. Anyone who had already moved the HUD has set it up; they are not asked.
function W.MaybeAsk()
  local db = ns.db
  if not db or db.welcomed then
    return
  end
  if type(db.point) == "table" then
    db.welcomed = true
    return
  end
  if ns.State.combatStart then
    return
  end
  W.Open()
end
