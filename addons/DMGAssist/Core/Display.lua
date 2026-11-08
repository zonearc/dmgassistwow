-- Display.lua: the HUD. One large icon (next spell) and one small icon (major cooldown, burst toggle on).
-- Shown in combat or with an attackable target. Drag to move while unlocked (/dmga lock).

local _, ns = ...
local U = ns.U

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

local function Icon(parent, size)
  local f = CreateFrame("Frame", nil, parent)
  f:SetSize(size, size)
  f.tex = f:CreateTexture(nil, "ARTWORK")
  f.tex:SetAllPoints(f)
  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -2, 2)
  return f
end

function D.Create()
  if D.frame then
    return D.frame
  end
  local db = ns.db or {}
  local f = CreateFrame("Frame", "DMGAssistDisplay", UIParent)
  f:SetSize(52, 52)
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
  f.main = Icon(f, 52)
  f.main:SetPoint("CENTER", f, "CENTER", 0, 0)
  f.cd = Icon(f, 34)
  f.cd:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", 4, 0)
  f.cd:Hide()
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
  SetIcon(f.main, result.main)
  SetIcon(f.cd, result.cd)
  f:Show()
end

function D.SetLocked(locked)
  local f = D.Create()
  f:EnableMouse(not locked)
end
