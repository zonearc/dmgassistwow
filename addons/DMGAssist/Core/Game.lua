-- Game.lua: Game mode, the HUD as a rhythm game (asked for 2026-11-11: "like Guitar Hero... a mini game").
--
-- Three lanes scroll right to left into a hit line on the left:
--   top    - the damage rotation (slots 1-3; an interrupt drops in here too, gold-edged),
--   middle - defensives, heals and tank mitigation (the red icon of the classic HUD),
--   bottom - trinkets, potions and other items (the gold icon).
-- A spell's note reaches the line exactly when it can be pressed: the same clock as the classic HUD's press-now
-- flash (Display.RenderTiming), so a 1.5 s global cooldown is a 1.5 s slide. Slots 2-3 follow behind it.
-- Presses are judged by the performance grade (Grade.OnPress): the right spell is a hit (Perfect / Great / Good by
-- how close to the line), slot 2 or 3 a Good, anything else a miss. Hits build a streak; 5, 10, 25, 50, 100 and 200
-- in a row pop a word and add a star. The best streak per spec is kept.
--
-- What slot 1 says is never changed (it's the right press); slots 2-3 only swap when the new pick holds for STICK
-- seconds, so the lane doesn't jitter when the engine's look-ahead flickers. Purely visual: nothing is pressed for
-- you. Switch with the controller button on either HUD, /dmga game, or the minimap menu.

local _, ns = ...
local U, L = ns.U, ns.L

local G = {}
ns.Game = G

G.LOOK = 4          -- seconds of lane shown ahead of the hit line
G.WIDTH = 330
G.LANE = 40
G.ICON = 32
G.HIT_X = 28        -- the hit line, from the left edge
G.HEAD = 20         -- streak row above the lanes
G.STICK = 0.35      -- seconds a new slot 2-3 pick must hold before its note swaps
G.GLIDE = 14        -- how fast a note glides to a new place (per second, exponential)
G.PERFECT, G.GREAT = 0.25, 0.6 -- seconds from the line
G.IDLE_BREAK = 3    -- a note waiting at the line this long without a press breaks the streak
G.MILESTONES = { 5, 10, 25, 50, 100, 200 }
G.WORDS = { [5] = "Nice!", [10] = "Great!", [25] = "Awesome!", [50] = "On fire!", [100] = "Unstoppable!",
  [200] = "Legendary!" }
G.JUDGE_TEXT = { perfect = "Perfect!", great = "Great", good = "Good", miss = "Miss" }
G.JUDGE_COLOR = { perfect = { 1, 0.85, 0.2 }, great = { 0.4, 1, 0.4 }, good = { 0.6, 0.8, 1 }, miss = { 1, 0.3, 0.3 } }
G.LANE_COLOR = { { 1, 0.8, 0.3 }, { 1, 0.3, 0.3 }, { 0.4, 0.7, 1 } }
G.TOGGLE_ICON = "Interface\\Icons\\INV_Misc_Drum_01"

G.streak, G.stars = 0, 0
G.notes = {}

function G.On()
  return ns.db ~= nil and ns.db.gameMode == true
end

local function SpecKey()
  local s = ns.Specs and ns.Specs.current
  return s and s.key or "none"
end

function G.Best(key)
  local b = ns.db and type(ns.db.gameBest) == "table" and ns.db.gameBest
  return b and tonumber(b[key or SpecKey()]) or 0
end

local function SaveBest()
  if not ns.db then
    return
  end
  ns.db.gameBest = type(ns.db.gameBest) == "table" and ns.db.gameBest or {}
  local key = SpecKey()
  if G.streak > (tonumber(ns.db.gameBest[key]) or 0) then
    ns.db.gameBest[key] = G.streak
  end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
-- The switch: a small drum icon, on the classic HUD and on the lanes, always clickable.
function G.ToggleButton(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(16, 16)
  b.tex = b:CreateTexture(nil, "ARTWORK")
  b.tex:SetAllPoints(b)
  b.tex:SetTexture(G.TOGGLE_ICON)
  b:SetAlpha(0.7)
  b:SetScript("OnClick", function()
    G.Toggle()
  end)
  b:SetScript("OnEnter", function(self)
    if GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(G.On() and L["Game mode: on (click for the classic HUD)"]
        or L["Game mode: off (click to play it as a game)"], 1, 1, 1)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function()
    if GameTooltip then
      GameTooltip:Hide()
    end
  end)
  return b
end

local function Place(f)
  f:ClearAllPoints()
  local pos = ns.db and type(ns.db.gamePoint) == "table" and ns.db.gamePoint
  if pos then
    f:SetPoint(pos[1] or "CENTER", UIParent, pos[2] or "CENTER", tonumber(pos[3]) or 0, tonumber(pos[4]) or -150)
  else
    local home = ns.Display.Home and ns.Display.Home()
    if home then
      f:SetPoint("LEFT", home, "LEFT", 0, 0)
    else
      f:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
    end
  end
end

function G.Create()
  if G.frame then
    return G.frame
  end
  local D = ns.Display
  local f = CreateFrame("Frame", "DMGAssistGame", UIParent)
  G.frame = f
  f:SetSize(G.WIDTH, G.HEAD + 3 * G.LANE)
  f:SetFrameStrata("MEDIUM")
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, rel, x, y = self:GetPoint(1)
    ns.db.gamePoint = { point, rel, math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
  end)
  f:EnableMouse(false)
  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -G.HEAD)
  f.bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
  f.bg:SetColorTexture(0.04, 0.04, 0.07, 0.55)
  f.lanes = {}
  for i = 1, 3 do
    local t = f:CreateTexture(nil, "BORDER")
    local c = G.LANE_COLOR[i]
    t:SetColorTexture(c[1], c[2], c[3], 0.08)
    t:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(G.HEAD + (i - 1) * G.LANE) - 2)
    t:SetSize(G.WIDTH, G.LANE - 4)
    f.lanes[i] = t
  end
  -- the hit line, and a box per lane where the notes land
  f.line = f:CreateTexture(nil, "ARTWORK")
  f.line:SetColorTexture(1, 0.82, 0.25, 0.9)
  f.line:SetPoint("TOPLEFT", f, "TOPLEFT", G.HIT_X - 1, -G.HEAD)
  f.line:SetSize(2, 3 * G.LANE)
  f.boxes = {}
  for i = 1, 3 do
    local b = f:CreateTexture(nil, "ARTWORK")
    b:SetColorTexture(1, 1, 1, 0.1)
    b:SetSize(G.ICON + 6, G.ICON + 6)
    b:SetPoint("CENTER", f, "TOPLEFT", G.HIT_X, -(G.HEAD + (i - 0.5) * G.LANE))
    f.boxes[i] = b
  end
  f.streak = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.streak, 13)
  f.streak:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -3)
  f.stars = {}
  f.toggle = G.ToggleButton(f)
  f.toggle:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -2)
  -- the judgement ("Perfect!") over the line, and the streak word ("On fire!") in the middle of the lanes
  f.judge = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.judge, 14)
  f.judge:SetPoint("BOTTOMLEFT", f, "TOPLEFT", G.HIT_X - 10, -G.HEAD + 2)
  f.judge:Hide()
  f.pop = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.pop, 24)
  f.pop:SetPoint("CENTER", f, "CENTER", 30, -G.HEAD / 2)
  f.pop:SetTextColor(1, 0.85, 0.2)
  f.pop:Hide()
  f.slip = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.slip, 12)
  f.slip:SetPoint("TOP", f, "BOTTOMLEFT", G.HIT_X, -2)
  f.slip:SetTextColor(1, 0.55, 0.2)
  f.slip:Hide()
  f:SetScript("OnUpdate", function()
    G.Render()
  end)
  Place(f)
  f:Hide()
  return f
end

local function Star(f, i)
  local s = f.stars[i]
  if not s then
    s = f:CreateTexture(nil, "OVERLAY")
    s:SetTexture("Interface\\COMMON\\FavoritesIcon")
    s:SetSize(14, 14)
    s:SetPoint("TOPRIGHT", f, "TOPRIGHT", -(4 + (i - 1) * 15), -3)
    f.stars[i] = s
  end
  return s
end

local function RenderStreak(f)
  local best = G.Best()
  local text = string.format(L["Streak %d"], G.streak)
  if best > 0 then
    text = text .. "  |cff999999" .. string.format(L["Best %d"], best) .. "|r"
  end
  f.streak:SetText(text)
  for i = 1, #G.MILESTONES do
    local s = (i <= G.stars) and Star(f, i) or f.stars[i]
    if s then
      s:SetShown(i <= G.stars)
    end
  end
end

---------------------------------------------------------------------------
-- Notes
---------------------------------------------------------------------------
local function NewNote(f)
  local cfg = ns.Display.Settings()
  local n = ns.Display.NewIcon(f, G.ICON, cfg)
  n.edge = n:CreateTexture(nil, "BACKGROUND")
  n.edge:SetPoint("TOPLEFT", n, "TOPLEFT", -2, 2)
  n.edge:SetPoint("BOTTOMRIGHT", n, "BOTTOMRIGHT", 2, -2)
  n.edge:SetColorTexture(1, 1, 1, 0.5)
  return n
end

-- Where a note wants to be: x of its center for `t` seconds before the line.
local function XFor(t)
  local px = (G.WIDTH - G.HIT_X - G.ICON / 2 - 2) / G.LOOK
  return G.HIT_X + math.max(0, math.min(G.LOOK, t)) * px
end

-- The notes we want this frame: { key, lane, pick, t, special } in each lane. Keyed by spell (and its place),
-- so a note keeps sliding when the queue moves up (slot 2 becomes slot 1 after a press).
local function Wanted(r, wait)
  local want = {}
  local q = G.queue or {}
  local t = math.max(0, wait or 0)
  local seen = {}
  for i = 1, 3 do
    local p = q[i]
    if p and p.id then
      local k = tostring(p.item or p.id)
      seen[k] = (seen[k] or 0) + 1
      want[#want + 1] = { key = "1:" .. k .. ":" .. seen[k], lane = 1, pick = p, t = t, main = i == 1 }
      local gcd = (ns.State.GCD and ns.State.GCD(p.id)) or 1.5
      local info = U.Get(C_Spell and C_Spell.GetSpellInfo, p.id)
      local cast = type(info) == "table" and tonumber(U.Read(info.castTime)) or 0
      t = t + math.max(gcd, (cast or 0) / 1000)
    end
  end
  local intr = r.interrupt
  if intr and intr.id and (intr.how == "decided" or intr.how == "render") then
    want[#want + 1] = { key = "1:kick", lane = 1, pick = { id = intr.id, source = "interrupt" }, t = 0,
      special = "interrupt", intr = intr }
  end
  local d = r.defensive
  local w = r.weave
  if d and d.id and (d.how == "decided" or d.how == "render") then
    want[#want + 1] = { key = "2:def:" .. d.id, lane = 2, pick = { id = d.id, source = "defensive" }, t = 0,
      special = d.how == "render" and "health" or "urgent", def = d }
  elseif w and w.id then
    want[#want + 1] = { key = "2:" .. tostring(w.id), lane = 2, pick = w, t = 0, special = w.urgent and "urgent" }
  end
  local it = r.trinket
  if it and (it.id or it.item) then
    want[#want + 1] = { key = "3:" .. tostring(it.item or it.id), lane = 3, pick = it, t = 0 }
  end
  return want
end

-- Slots 2-3 swap only when the new pick holds (slot 1 is always the truth: it's the right press).
function G.Steady(queue, now)
  local q = {}
  for i, p in ipairs(queue or {}) do
    q[i] = p
  end
  G.held = G.held or {}
  for i = 2, 3 do
    local new, old = q[i], G.held[i]
    local newID = new and (new.item or new.id)
    local oldID = old and old.pick and (old.pick.item or old.pick.id)
    if newID == oldID or not old then
      G.held[i] = new and { pick = new, since = now } or nil
    elseif G.pending and G.pending[i] and G.pending[i].id == newID then
      if now - G.pending[i].since >= G.STICK then
        G.held[i] = { pick = new, since = now }
        G.pending[i] = nil
      else
        q[i] = old.pick
      end
    else
      G.pending = G.pending or {}
      G.pending[i] = { id = newID, since = now }
      q[i] = old.pick
    end
    -- the held pick is now slot 1: nothing to hold back
    if q[i] and q[1] and (q[i].item or q[i].id) == (q[1].item or q[1].id) and newID ~= (q[i].item or q[i].id) then
      q[i] = new
      G.held[i] = new and { pick = new, since = now } or nil
    end
  end
  return q
end

function G.Render()
  local f = G.frame
  local r = G.result
  if not (f and r and f:IsShown()) then
    return
  end
  local D = ns.Display
  local cfg = D.Settings()
  local now = GetTime()
  local df = D.frame
  local wait = df and df.lastWait or 0
  local elapsed = math.min(0.1, now - (G.lastRender or now))
  G.lastRender = now
  local want = Wanted(r, wait)
  local keep = {}
  for _, w in ipairs(want) do
    local n = G.notes[w.key]
    if not n then
      n = table.remove(G.pool or {}) or NewNote(f)
      n.x = G.WIDTH + G.ICON -- slides in from the right
      n.fade = nil
      G.notes[w.key] = n
    end
    keep[w.key] = true
    n.lane, n.main = w.lane, w.main
    D.SetIcon(n, w.pick, cfg, w.main or w.lane > 1, "")
    n.name:SetText("")
    n.label:SetText("")
    n.source:SetText("")
    local target = XFor(w.t)
    n.x = n.x + (target - n.x) * math.min(1, elapsed * G.GLIDE)
    if math.abs(n.x - target) < 0.5 then
      n.x = target
    end
    n:ClearAllPoints()
    n:SetPoint("CENTER", f, "TOPLEFT", n.x, -(G.HEAD + (w.lane - 0.5) * G.LANE))
    local c = G.LANE_COLOR[w.lane]
    if w.special == "interrupt" then
      n.edge:SetColorTexture(1, 0.85, 0.2, 0.9)
    elseif w.special == "urgent" or w.special == "health" then
      n.edge:SetColorTexture(1, 0.25, 0.25, 0.4 + 0.5 * math.abs(math.cos(now * math.pi * 1.5)))
    else
      n.edge:SetColorTexture(c[1], c[2], c[3], (w.main and w.t <= 0.05) and 0.95 or 0.35)
    end
    n:SetAlpha(w.main and 1 or (w.lane == 1 and 0.75 or 1))
    -- hidden facts the game decides (combat): the same alpha tricks as the classic HUD
    if w.intr and w.intr.how == "render" then
      D.SetAlphaBool(n, w.intr.notInterruptible, 0, 1)
    elseif w.def and w.def.how == "render" then
      local a = D.HealthAlpha(w.def.threshold)
      if a == nil then
        n:SetAlpha(0)
      else
        n:SetAlpha(a)
      end
    end
    if w.main then
      if w.t <= 0.05 then
        G.arrived = G.arrived or { id = w.pick.id, at = now }
        if G.arrived.id ~= w.pick.id then
          G.arrived = { id = w.pick.id, at = now }
        end
        if G.streak > 0 and ns.State.combatStart and now - G.arrived.at > G.IDLE_BREAK and not G.idleBroken then
          G.idleBroken = true
          G.Break()
        end
      else
        G.arrived, G.idleBroken = nil, nil
      end
    end
    n:Show()
  end
  -- notes no longer wanted: pressed (or swapped) - fade out where they are
  for key, n in pairs(G.notes) do
    if not keep[key] then
      n.fade = n.fade or now
      local a = 1 - (now - n.fade) / 0.25
      if a <= 0 then
        n:Hide()
        G.notes[key] = nil
        G.pool = G.pool or {}
        G.pool[#G.pool + 1] = n
      else
        n:SetAlpha(a)
        n:SetPoint("CENTER", f, "TOPLEFT", n.x, -(G.HEAD + ((n.lane or 1) - 0.5) * G.LANE))
      end
    end
  end
  -- pop-ups fade
  for _, fs in ipairs({ f.judge, f.pop, f.slip }) do
    if fs:IsShown() and fs.at then
      local life = fs == f.pop and 1.4 or 0.8
      local a = 1 - (now - fs.at) / life
      if a <= 0 then
        fs:Hide()
      else
        fs:SetAlpha(a)
      end
    end
  end
  RenderStreak(f)
end

---------------------------------------------------------------------------
-- Called by the HUD and the grade
---------------------------------------------------------------------------
-- Every HUD update (Display.Update), while game mode is on.
function G.Update(result, visible)
  if not G.On() then
    if G.frame then
      G.frame:Hide()
    end
    return
  end
  local f = G.Create()
  if not visible or not result or not result.main then
    f:Hide()
    return
  end
  G.result = result
  G.queue = G.Steady(result.queue or { result.main }, GetTime())
  f:SetScale(ns.Display.Settings().scale or 1)
  f:Show()
end

local function Flash(fs, text, color)
  fs:SetText(text)
  if color then
    fs:SetTextColor(color[1], color[2], color[3])
  end
  fs.at = GetTime()
  fs:SetAlpha(1)
  fs:Show()
end

function G.Break()
  if G.streak > 0 then
    SaveBest()
  end
  G.streak, G.stars = 0, 0
end

-- From the grade, for each press it judges: "hit" (slot 1), "near" (slot 2 or 3), "miss" (anything else).
function G.OnJudged(kind)
  if not G.On() then
    return
  end
  local f = G.Create()
  local judge
  if kind == "miss" then
    judge = "miss"
    G.Break()
  else
    if kind == "near" then
      judge = "good"
    else
      local arrived = G.arrived and G.arrived.at
      local wait = ns.Display.frame and ns.Display.frame.lastWait or 0
      local off = arrived and (GetTime() - arrived) or -wait -- early (queued) presses: negative
      if math.abs(off) <= G.PERFECT then
        judge = "perfect"
      elseif math.abs(off) <= G.GREAT then
        judge = "great"
      else
        judge = "good"
      end
    end
    G.streak = G.streak + 1
    G.idleBroken = nil
    G.arrived = nil -- the next note's arrival is timed afresh
    for i, m in ipairs(G.MILESTONES) do
      if G.streak == m then
        G.stars = i
        Flash(f.pop, L[G.WORDS[m]])
      end
    end
    if G.streak > G.Best() then
      SaveBest()
    end
  end
  G.lastJudge = judge
  Flash(f.judge, L[G.JUDGE_TEXT[judge]], G.JUDGE_COLOR[judge])
end

-- A key slip ("5 » 6") shows under the hit line instead of under slot 1.
function G.ShowSlip(got, want)
  local f = G.Create()
  Flash(f.slip, tostring(got) .. " \194\187 " .. tostring(want))
end

-- A fight ends: the streak carries on to the next fight (a streak is about your presses, not one pull).
function G.OnCombat(inCombat)
  if not inCombat and G.streak > 0 then
    SaveBest()
  end
end

function G.SetLocked(locked)
  if G.frame then
    G.frame:EnableMouse(not locked)
  end
end

function G.Toggle(on)
  if not ns.db then
    return
  end
  if on == nil then
    on = not G.On()
  end
  ns.db.gameMode = on and true or false
  U.Print("%s", on and L["Game mode on: hit each note as it reaches the line. Click the drum (or /dmga game) to switch back."]
    or L["Game mode off: the classic HUD is back."])
  if not on and G.frame then
    G.frame:Hide()
  end
  if ns.Update then
    ns.Update()
  end
end
