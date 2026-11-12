-- Welcome.lua: four questions the first time DMGAssist runs (per settings profile, so alts sharing the Default
-- profile are asked once): where the HUD goes, how big, when it shows, and Classic or Flow (two cards). Each has a
-- suggested answer; "Use the suggestions" answers the rest at once. Asked again with /dmga welcome or the button on the main settings page.
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

-- Next to the character: most UIs keep that space free (unit frames and bars sit lower and to the sides).
W.Place = function(point)
  return Place(point)
end
W.RIGHT = { "CENTER", "CENTER", 190, -40 }
W.BELOW = { "CENTER", "CENTER", 0, -125 }

-- Just above the main action bar (wherever the player's UI puts it), else a sensible spot low in the middle.
function W.AboveBars()
  local bar = _G.MainActionBar or _G.MainMenuBar
  local top = bar and U.Get(bar.GetTop, bar)
  local scale = bar and U.Get(bar.GetEffectiveScale, bar) or 1
  local uiScale = U.Get(UIParent.GetEffectiveScale, UIParent) or 1
  local y = type(top) == "number" and (top * scale / uiScale + 90) or 260
  return { "BOTTOM", "BOTTOM", 0, math.floor(y) }
end

-- Unlocks the HUD to drag. It never opens Blizzard's Edit Mode itself: an addon showing EditModeManagerFrame taints
-- Edit Mode and everything it touches (party frames, action bars). Edit Mode is in the game menu (Esc).
local function OpenEditMode()
  ns.db.locked = false
  ns.Display.SetLocked(false)
  U.Print("%s", L["The HUD is unlocked: drag it where you like, then lock it in Settings > DMGAssist."])
  return false
end

W.QUESTIONS = {
  { text = "Where should the recommendations go?",
    options = {
      { "To the right of my character", function()
        Place(W.RIGHT)
      end },
      { "Right below my character's feet", function()
        Place(W.BELOW)
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
  { text = "Pick your style", pick = true,
    options = {
      { "Classic: the next three spells as icons", function()
        ns.db.gameMode = false
      end },
      { "Flow mode: notes slide into a hit line, with streaks", function()
        ns.db.gameMode = true
      end },
    } },
}

local frame, step

-- The style question: two cards side by side, each with a small live preview (2026-11-12: "left Classic with its
-- 3 boxes, right Flow with a mockup, a sentence each, and that you can switch any time").
W.CARDS = {
  { title = "CLASSIC", text = "Your next three spells as icons. Press the big one." },
  { title = "FLOW", text = "Spells slide into the box. Press each one as it lands and build a streak." },
}
local ICONS = { 136048, 132096, 135808 } -- generic spell icons for the previews
local function Card(parent, n)
  local c = CreateFrame("Button", nil, parent, "BackdropTemplate")
  c:SetSize(204, 150)
  if c.SetBackdrop then
    c:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
    c:SetBackdropColor(0.05, 0.05, 0.07, 0.9)
    c:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
  end
  c.title = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  c.title:SetPoint("TOP", 0, -8)
  c.preview = CreateFrame("Frame", nil, c)
  c.preview:SetSize(184, 50)
  c.preview:SetPoint("TOP", 0, -34)
  c.text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  c.text:SetPoint("TOPLEFT", c.preview, "BOTTOMLEFT", 0, -8)
  c.text:SetWidth(184)
  c.text:SetJustifyH("LEFT")
  if n == 1 then
    -- three icons, the first one big
    for i, tex in ipairs(ICONS) do
      local t = c.preview:CreateTexture(nil, "ARTWORK")
      local size = i == 1 and 46 or 32
      t:SetSize(size, size)
      t:SetTexture(tex)
      t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      if i == 1 then
        t:SetPoint("LEFT", 20, 0)
      else
        t:SetPoint("LEFT", c.preview.icons[i - 1], "RIGHT", 6, i == 2 and -7 or 0)
      end
      c.preview.icons = c.preview.icons or {}
      c.preview.icons[i] = t
    end
  else
    -- a lane: a gold box on the left, notes sliding into it
    local lane = c.preview:CreateTexture(nil, "BACKGROUND")
    lane:SetAllPoints()
    lane:SetColorTexture(0.12, 0.12, 0.16, 1)
    local box = c.preview:CreateTexture(nil, "BORDER")
    box:SetSize(40, 40)
    box:SetPoint("LEFT", 6, 0)
    box:SetColorTexture(1, 0.8, 0.2, 0.35)
    c.preview.notes = {}
    for i, tex in ipairs(ICONS) do
      local t = c.preview:CreateTexture(nil, "ARTWORK")
      t:SetSize(32, 32)
      t:SetTexture(tex)
      t:SetTexCoord(0.08, 0.92, 0.08, 0.92)
      c.preview.notes[i] = t
    end
    c.preview:SetScript("OnUpdate", function(self)
      local w = self:GetWidth() or 184
      local now = GetTime()
      for i, t in ipairs(self.notes) do
        local x = (w - 40) - ((now * 45 + (i - 1) * 60) % (w - 30))
        t:ClearAllPoints()
        t:SetPoint("LEFT", math.max(10, x), 0)
        t:SetAlpha(x < 10 and 0 or 1)
      end
    end)
  end
  c:SetScript("OnEnter", function(self)
    if self.SetBackdropBorderColor then
      self:SetBackdropBorderColor(1, 0.8, 0.2, 1)
    end
  end)
  c:SetScript("OnLeave", function(self)
    if self.SetBackdropBorderColor then
      self:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
    end
  end)
  return c
end

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
  for n, card in ipairs(frame.cards) do
    card:SetShown(q.pick == true)
    card.title:SetText(L[W.CARDS[n].title])
    card.text:SetText(L[W.CARDS[n].text])
  end
  frame.switchNote:SetShown(q.pick == true)
  for n, button in ipairs(frame.buttons) do
    local o = not q.pick and q.options[n]
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
  frame:SetSize(460, 300)
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
  frame.cards = {}
  for n = 1, 2 do
    local c = Card(frame, n)
    c:SetPoint("TOPLEFT", frame.question, "BOTTOMLEFT", (n - 1) * 216, -10)
    c:SetScript("OnClick", function()
      Answer(n)
    end)
    c:Hide()
    frame.cards[n] = c
  end
  frame.switchNote = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  frame.switchNote:SetPoint("TOPLEFT", frame.cards[1], "BOTTOMLEFT", 0, -6)
  frame.switchNote:SetWidth(420)
  frame.switchNote:SetJustifyH("LEFT")
  frame.switchNote:SetText(L["Switch any time with the CLASSIC / FLOW switch under the HUD."])
  frame.switchNote:Hide()
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
