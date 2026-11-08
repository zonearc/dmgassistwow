-- Display.lua: the HUD.
--   [ next ] [ then ] [ then ]   (first icon large: press this when the GCD ends)
--   [ cooldown ]                  (major cooldown, while the burst toggle is on)
--   mode label: ST / AOE / AUTO n  (hotkey or /dmga mode to switch)
-- Shown in combat or with an attackable target. Drag to move while unlocked (/dmga lock).

local _, ns = ...
local U, L = ns.U, ns.L

local D = {}
ns.Display = D

local SOURCE_TEXT = {
  simc = "",
  ["simc+assisted"] = "",
  ["simc+rules"] = "",
  assisted = "AC",
  rules = "B",
  ["rules?"] = "?",
  guess = "?",
}

local MAIN_SIZE, NEXT_SIZE, CD_SIZE, GAP = 52, 34, 34, 4

local function Icon(parent, size)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size, size)
  f.tex = f:CreateTexture(nil, "ARTWORK")
  f.tex:SetAllPoints(f)
  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  f:Hide()
  return f
end

function D.Create()
  if D.frame then
    return D.frame
  end
  local db = ns.db or {}
  local f = CreateFrame("Frame", "DMGAssistDisplay", UIParent)
  f:SetSize(MAIN_SIZE, MAIN_SIZE)
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
  f.slots = {}
  f.slots[1] = Icon(f, MAIN_SIZE)
  f.slots[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
  for i = 2, 3 do
    f.slots[i] = Icon(f, NEXT_SIZE)
    f.slots[i]:SetPoint("BOTTOMLEFT", f.slots[i - 1], "BOTTOMRIGHT", GAP, 0)
  end
  f.main = f.slots[1]
  f.cd = Icon(f, CD_SIZE)
  f.cd:SetPoint("TOPLEFT", f.slots[1], "BOTTOMLEFT", 0, -GAP)
  f.mode = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.mode:SetPoint("BOTTOMLEFT", f.slots[1], "TOPLEFT", 0, 2)
  f:Hide()
  D.frame = f
  return f
end

local function SetIcon(icon, pick)
  if not pick then
    icon:Hide()
    return
  end
  local tex = U.Read(U.Call(C_Spell and C_Spell.GetSpellTexture, pick.id))
  icon.tex:SetTexture(tex or 134400) -- 134400: question mark icon
  icon.label:SetText(SOURCE_TEXT[pick.source] or "")
  icon:Show()
end

function D.Update(result, visible)
  local f = D.Create()
  if not visible or not result or not result.main then
    f:Hide()
    return
  end
  local depth = (ns.db and tonumber(ns.db.queue)) or 3
  local queue = result.queue or { result.main }
  for i = 1, 3 do
    SetIcon(f.slots[i], i <= depth and queue[i] or nil)
  end
  SetIcon(f.cd, result.cd)
  f.mode:SetText((tostring(result.modeLabel or ""):gsub("%a+", function(word)
    return L[word]
  end)))
  f:Show()
end

function D.SetLocked(locked)
  local f = D.Create()
  f:EnableMouse(not locked)
end
