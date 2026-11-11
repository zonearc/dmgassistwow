-- Game.lua: Game mode, the HUD as a rhythm game (asked for 2026-11-11: "like Guitar Hero... a mini game").
--
-- Three lanes scroll right to left into a hit line on the left:
--   top    - the damage rotation (slots 1-3; an interrupt drops in here too, gold-edged),
--   middle - defensives, heals and tank mitigation (the red icon of the classic HUD),
--   bottom - trinkets, potions and other items (the gold icon).
-- A spell's note reaches the line exactly when it can be pressed: the same clock as the classic HUD's press-now
-- flash (Display.RenderTiming), so a 1.5 s global cooldown is a 1.5 s slide. Slots 2-3 follow behind it.
-- Presses are judged by the performance grade (Grade.OnPress): the right spell is a hit (Perfect / Great / Good by
-- how close to the line), slot 2 or 3 a Good, anything else a miss. Hits build a streak and a score: points per hit
-- (Perfect 100, Great 75, Good 50) times a multiplier that grows every 10 in a row (up to x4). Streak milestones pop
-- a word that escalates (Nice! ... Streak Champion! ... Immortal!) and earn stars and a rank (Bronze ... Mythic).
-- A set is a run of pulls: it lasts until you've been out of combat SET_GAP seconds (chain pulls, a long boss and
-- the trash after it are one set); then the performance grade shows with the set's score and best streak.
-- Only a wrong spell breaks the streak: waiting (nothing to hit, moving, a mechanic) never does.
-- The note flashes the line the moment it can be pressed; "Game timing offset" (ms) moves that moment for latency
-- and reaction, like a rhythm game's calibration.
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
G.SET_GAP = 20      -- seconds out of combat that end a set (and bring the grade)
G.FLASH = 0.3       -- the hit box's flash when a note reaches the line
G.POINTS = { perfect = 100, great = 75, good = 50 }
G.MULT_EVERY, G.MULT_MAX = 10, 4
G.MILESTONES = { 5, 10, 15, 25, 40, 50, 75, 100, 150, 200, 300, 500 }
G.WORDS = { [5] = "Nice!", [10] = "Great streak!", [15] = "Keep it up!", [25] = "Awesome!", [40] = "Excellent!",
  [50] = "On fire!", [75] = "Blazing!", [100] = "Unstoppable!", [150] = "Streak Champion!", [200] = "Legendary!",
  [300] = "Godlike!", [500] = "Immortal!" }
G.STAR_MAX = 5
-- rank by streak: { from, name, color }
G.RANKS = { { 10, "Bronze", { 0.8, 0.5, 0.25 } }, { 25, "Silver", { 0.8, 0.8, 0.85 } }, { 50, "Gold", { 1, 0.82, 0.2 } },
  { 100, "Platinum", { 0.6, 0.9, 1 } }, { 200, "Diamond", { 0.55, 0.75, 1 } }, { 500, "Mythic", { 1, 0.5, 0.1 } } }
-- what a press says: mild first, more excited later in each list; the multiplier unlocks the later ones
G.PHRASES = {
  perfect = { "PERFECT!", "Spot on!", "Bullseye!", "Flawless!", "Right on the beat!" },
  great = { "Great!", "Nice timing!", "Sharp!", "Excellent!", "Well played!" },
  good = { "Good", "Not bad", "Almost!", "Keep it up", "Nice try" },
  miss = { "Oh, too bad...", "Missed!", "So close...", "Shake it off", "Next one!" },
}
G.JUDGE_COLOR = { perfect = { 1, 0.85, 0.2 }, great = { 0.4, 1, 0.4 }, good = { 0.6, 0.8, 1 }, miss = { 1, 0.3, 0.3 } }
G.LANE_COLOR = { { 1, 0.8, 0.3 }, { 1, 0.3, 0.3 }, { 0.4, 0.7, 1 } }
G.TOGGLE_ICON = "Interface\\Icons\\INV_Misc_Drum_01"

G.streak, G.stars = 0, 0
G.score, G.setBest, G.hits, G.perfects = 0, 0, 0, 0
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

function G.Mult()
  return math.min(G.MULT_MAX, 1 + math.floor(G.streak / G.MULT_EVERY))
end

function G.Rank()
  local rank
  for _, r in ipairs(G.RANKS) do
    if G.streak >= r[1] then
      rank = r
    end
  end
  return rank
end

-- ms: positive = the note reaches the line (and flashes) that much earlier, for someone who presses late
function G.Offset()
  local hud = ns.db and ns.db.hud
  return (tonumber(hud and hud.gameOffset) or 0) / 1000
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
  local text = string.format(L["Streak %d"], G.streak) .. "  |cffffd100x" .. G.Mult() .. "|r  "
    .. string.format(L["Score %d"], G.score)
  local rank = G.Rank()
  if rank then
    local c = rank[3]
    text = text .. string.format("  |cff%02x%02x%02x%s|r", c[1] * 255, c[2] * 255, c[3] * 255, L[rank[2]])
  end
  if best > 0 then
    text = text .. "  |cff999999" .. string.format(L["Best %d"], best) .. "|r"
  end
  f.streak:SetText(text)
  for i = 1, G.STAR_MAX do
    local s = (i <= G.stars) and Star(f, i) or f.stars[i]
    if s then
      s:SetShown(i <= math.min(G.STAR_MAX, G.stars))
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
  local wait = (df and df.lastWait or 0) - G.Offset()
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
        -- reaching the line: one flash of the hit box, the instant it can be pressed (waiting never costs you)
        if not G.arrived or G.arrived.id ~= w.pick.id then
          G.arrived = { id = w.pick.id, at = now }
          f.flashAt = now
        end
      else
        G.arrived = nil
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
  local fl = f.flashAt and (1 - (now - f.flashAt) / G.FLASH) or 0
  if fl > 0 then
    f.boxes[1]:SetColorTexture(1, 0.85, 0.3, 0.15 + 0.75 * fl)
  else
    f.boxes[1]:SetColorTexture(1, 1, 1, 0.1)
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
  -- The settings preview: the lanes take the docked HUD's place, so what you set is what you see.
  local preview = ns.Display.InPreview and ns.Display.InPreview()
  if preview and not G.docked then
    G.docked = true
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", ns.Display.frame, "TOPLEFT", 0, 0)
  elseif not preview and G.docked then
    G.docked = false
    f:SetFrameStrata("MEDIUM")
    Place(f)
  end
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

-- A word from a list: the mild end at x1, more of the list as the multiplier grows.
local function Phrase(list)
  local upto = math.min(#list, 1 + G.Mult())
  return L[list[math.random(upto)]]
end
G.Phrase = Phrase

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
      local wait = (ns.Display.frame and ns.Display.frame.lastWait or 0) - G.Offset()
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
    G.hits = G.hits + 1
    if judge == "perfect" then
      G.perfects = G.perfects + 1
    end
    G.score = G.score + G.POINTS[judge] * G.Mult()
    G.setBest = math.max(G.setBest, G.streak)
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
  Flash(f.judge, Phrase(G.PHRASES[judge]), G.JUDGE_COLOR[judge])
end

-- The set ends (the grade is being made, after SET_GAP out of combat): its numbers for the grade, then a fresh set.
function G.EndSet()
  if not G.On() or (G.hits == 0 and G.score == 0) then
    return nil
  end
  SaveBest()
  local best = ns.db and type(ns.db.gameBestScore) == "table" and ns.db.gameBestScore or {}
  if ns.db then
    ns.db.gameBestScore = best
  end
  local key = SpecKey()
  local newBest = G.score > (tonumber(best[key]) or 0)
  if newBest then
    best[key] = G.score
  end
  local out = { score = G.score, bestStreak = G.setBest, hits = G.hits, newBest = newBest,
    perfect = G.hits > 0 and math.floor(100 * G.perfects / G.hits + 0.5) or 0 }
  G.score, G.setBest, G.hits, G.perfects = 0, 0, 0, 0
  G.streak, G.stars = 0, 0
  return out
end

-- A key slip ("5 » 6") shows under the hit line instead of under slot 1.
function G.ShowSlip(got, want)
  local f = G.Create()
  Flash(f.slip, tostring(got) .. " \194\187 " .. tostring(want))
end

-- A fight ends: the streak and score carry on to the next pull; the set ends with the grade (Grade.lua waits
-- SET_GAP out of combat in Game mode).
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
