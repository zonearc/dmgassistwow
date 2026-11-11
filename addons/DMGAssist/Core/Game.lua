-- Game.lua: Game mode, the HUD as a rhythm game (asked for 2026-11-11: "like Guitar Hero... a mini game").
--
-- One lane scrolls right to left into a hit line on the left: the damage rotation (slots 1-3). Notes only ever
-- move left: after a press (a new global cooldown) or a wrong press they pause where they are and flow on when
-- their time catches up, never bounce back (2026-11-11: "the bounce is super annoying").
-- Everything else pops into the bonus row above the line when it's needed, as a bonus to grab: an interrupt
-- ("KICK!"), a defensive or heal ("DEFEND!"), a trinket or potion ("POWER UP!"). Grabbing one adds to the streak and
-- scores a bonus. (Three lanes were tried first: two of them sat empty most of the time.)
-- A spell's note reaches the line exactly when it can be pressed: the same clock as the classic HUD's press-now
-- flash (Display.RenderTiming), so a 1.5 s global cooldown is a 1.5 s slide. Slots 2-3 follow behind it.
-- Presses are judged by the performance grade (Grade.OnPress): the right spell is a hit (Perfect / Great / Good by
-- how close to the line), slot 2 or 3 a Good, anything else a miss. Hits build a streak and a score: points per hit
-- (Perfect 100, Great 75, Good 50) times a multiplier that grows every 10 in a row (up to x4). Streak milestones pop
-- a word that escalates (Nice! ... Streak Champion! ... Immortal!) and earn stars and a rank (Bronze ... Mythic).
-- A set is a run of pulls: it lasts until you've been out of combat SET_GAP seconds (chain pulls, a long boss and
-- the trash after it are one set); then the performance grade shows with the set's score and best streak.
-- Only a wrong spell breaks the streak: waiting (nothing to hit, moving, a mechanic) never does.
-- The note flashes the line the moment it can be pressed; "Flow timing offset" (ms) moves that moment for latency
-- and reaction, like a rhythm game's calibration.
--
-- What slot 1 says is never changed (it's the right press); slots 2-3 only swap when the new pick holds for STICK
-- seconds, so the lane doesn't jitter when the engine's look-ahead flickers. Purely visual: nothing is pressed for
-- you. Switch with the controller button on either HUD, /dmga flow, or the minimap menu.

local _, ns = ...
local U, L = ns.U, ns.L

local G = {}
ns.Game = G

G.LOOK = 4          -- seconds of lane shown ahead of the hit line
G.WIDTH = 560
G.LANE = 76
G.ICON = 56
G.HIT_X = 50        -- the hit line, from the left edge
G.HEAD = 0          -- (the streak row is below the lane, 2026-11-11: "put them below it")
G.FOOT = 36         -- the streak row, under the lane
G.BONUS_H = 62      -- the bonus row, between the streak row and the lane
G.BONUS_ICON = 48
G.DOT_EVERY = 0.5   -- the lane's dots: one per half second
G.BONUS_POINTS = 150
G.BONUS_TAG = { kick = "KICK!", defend = "DEFEND!", item = "POWER UP!" }
G.BONUS_DONE = { kick = "Interrupted!", defend = "Safe!", item = "Powered up!" }
G.MISS_SHOW = 0.7   -- the red X on a note after a wrong press
-- Guitar Hero's ideas, in WoW terms (asked 2026-11-11):
--   hold bars: a cast or channel's note trails a bar as long as the cast (yellow) or channel (blue); the next note
--     comes after it, so the gap is cast time, or the GCD when that's longer;
--   flame notes: a major cooldown is worth double (it's the hard part to get right) and burns orange;
--   power mode: while Bloodlust / a haste burst is up, or for POWER_TIME after a major cooldown, the lane turns
--     electric blue and every hit scores double.
G.FIRE_MULT = 2
G.POWER_MULT = 2
G.POWER_TIME = 15
G.BAR_H = 10
G.STICK = 0.35      -- seconds a new slot 2-3 pick must hold before its note swaps
-- One note in the box (2026-11-11: "two spells sitting in the cast location... I have no idea which one"): only
-- slot 1 may stand on the line. A note the engine moves back while it waits there drops away and comes in again
-- from the right; if it waited EXPIRE seconds with you free to press it, that's a miss (the score shows it).
G.EXPIRE = 1.2
-- A "next" the engine keeps putting off (Moonfire parked mid-lane for minutes, 2026-11-11) is hidden after it's
-- been passed over PASS_MAX times; it's back when it's slot 1 (the most a real slot 3 is passed over is twice).
G.PASS_MAX = 3
G.GAP_MIN = 8       -- pixels between two notes at the least, whatever their times
G.GLIDE = 14        -- how fast a note glides to a new place (per second, exponential)
G.PERFECT, G.GREAT = 0.25, 0.6 -- seconds from the line
G.SET_GAP = 20      -- seconds out of combat that end a set (and bring the grade)
G.FLASH = 0.5       -- the landing spot's flash (and burst) when a note reaches it
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
G.JUDGE_WORD = { perfect = "PERFECT!", great = "Great!", good = "Good", miss = "Missed!" }
G.JUDGE_COLOR = { perfect = { 1, 0.85, 0.2 }, great = { 0.4, 1, 0.4 }, good = { 0.6, 0.8, 1 }, miss = { 1, 0.3, 0.3 } }
G.LANE_COLOR = { { 1, 0.8, 0.3 }, { 1, 0.3, 0.3 }, { 0.4, 0.7, 1 } }

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
-- The switch: a two-way slider, CLASSIC | GAME, on the classic HUD and on the lanes, always clickable (2026-11-11:
-- "the drum is too small... something more mechanical looking that makes it absolutely clear"). The lit half is
-- the mode you're in; the knob slides across when you click.
G.SWITCH_W, G.SWITCH_H = 140, 22
G.switches = {}
local function SwitchRefresh(b, snap)
  local on = G.On()
  b.goal = on and 1 or 0
  if snap or not b.pos then
    b.pos = b.goal
  end
  local half = (G.SWITCH_W - 4) / 2
  b.knob:ClearAllPoints()
  b.knob:SetPoint("LEFT", b, "LEFT", 2 + b.pos * half, 0)
  local lit, dim = { 0.08, 0.06, 0.02 }, { 0.6, 0.6, 0.6 }
  local l, r = on and dim or lit, on and lit or dim
  b.left:SetTextColor(l[1], l[2], l[3])
  b.right:SetTextColor(r[1], r[2], r[3])
  if on then
    b.knob:SetColorTexture(1, 0.62, 0.15, 0.95)
  else
    b.knob:SetColorTexture(0.75, 0.8, 0.9, 0.9)
  end
end
G.SwitchRefresh = SwitchRefresh

function G.ToggleButton(parent)
  local b = CreateFrame("Button", nil, parent)
  b:SetSize(G.SWITCH_W, G.SWITCH_H)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints(b)
  b.bg:SetColorTexture(0.02, 0.02, 0.04, 0.85)
  b.edges = {}
  for i, side in ipairs({ { "TOPLEFT", "TOPRIGHT" }, { "BOTTOMLEFT", "BOTTOMRIGHT" }, { "TOPLEFT", "BOTTOMLEFT" },
    { "TOPRIGHT", "BOTTOMRIGHT" } }) do
    local e = b:CreateTexture(nil, "BORDER")
    e:SetColorTexture(1, 0.82, 0.3, 0.7)
    e:SetPoint(side[1], b, side[1], 0, 0)
    e:SetPoint(side[2], b, side[2], 0, 0)
    if i <= 2 then
      e:SetHeight(1)
    else
      e:SetWidth(1)
    end
    b.edges[i] = e
  end
  b.knob = b:CreateTexture(nil, "ARTWORK")
  b.knob:SetSize((G.SWITCH_W - 4) / 2, G.SWITCH_H - 4)
  b.left = b:CreateFontString(nil, "OVERLAY")
  ns.Display.SetFont(b.left, 11)
  b.left:SetPoint("CENTER", b, "LEFT", G.SWITCH_W / 4, 0)
  b.left:SetText(L["CLASSIC"])
  b.right = b:CreateFontString(nil, "OVERLAY")
  ns.Display.SetFont(b.right, 11)
  b.right:SetPoint("CENTER", b, "RIGHT", -G.SWITCH_W / 4, 0)
  b.right:SetText(L["FLOW"])
  SwitchRefresh(b, true)
  b:SetScript("OnClick", function()
    G.Toggle()
  end)
  b:SetScript("OnShow", function(self)
    SwitchRefresh(self, true)
  end)
  -- the knob slides; in combat the switch steps back (it's still there, and lights up under the mouse)
  b:SetScript("OnUpdate", function(self, elapsed)
    local goal = G.On() and 1 or 0
    if goal ~= self.goal then
      SwitchRefresh(self)
    end
    if self.pos ~= self.goal then
      local step = math.min(1, (elapsed or 0) * 10)
      self.pos = self.pos + (self.goal - self.pos) * step
      if math.abs(self.pos - self.goal) < 0.02 then
        self.pos = self.goal
      end
      SwitchRefresh(self)
    end
    local fight = UnitAffectingCombat and UnitAffectingCombat("player")
    local over = self.IsMouseOver and self:IsMouseOver()
    self:SetAlpha(over and 1 or (fight and 0.45 or 0.9))
  end)
  b:SetScript("OnEnter", function(self)
    if GameTooltip then
      GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
      GameTooltip:AddLine(G.On() and L["Flow mode: on (click for the classic HUD)"]
        or L["Flow mode: off (click to play the HUD like a rhythm game)"], 1, 1, 1)
      GameTooltip:Show()
    end
  end)
  b:SetScript("OnLeave", function()
    if GameTooltip then
      GameTooltip:Hide()
    end
  end)
  G.switches[#G.switches + 1] = b
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

function G.LaneY()
  return -(G.HEAD + G.BONUS_H + G.LANE / 2)
end

function G.BonusY()
  return -(G.HEAD + G.BONUS_H / 2 + 6)
end

function G.Create()
  if G.frame then
    return G.frame
  end
  local D = ns.Display
  local f = CreateFrame("Frame", "DMGAssistGame", UIParent)
  G.frame = f
  f:SetSize(G.WIDTH, G.HEAD + G.BONUS_H + G.LANE + G.FOOT)
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
  f.bg:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(G.HEAD + G.BONUS_H))
  f.bg:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, G.FOOT)
  f.bg:SetColorTexture(0.04, 0.04, 0.07, 0.55)
  f.lane = f:CreateTexture(nil, "BORDER")
  f.lane:SetColorTexture(1, 0.8, 0.3, 0.08)
  f.lane:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(G.HEAD + G.BONUS_H) - 2)
  f.lane:SetSize(G.WIDTH, G.LANE - 4)
  -- the hit line, and the box where the notes land
  f.line = f:CreateTexture(nil, "ARTWORK")
  f.line:SetColorTexture(1, 0.82, 0.25, 0.9)
  f.line:SetPoint("TOPLEFT", f, "TOPLEFT", G.HIT_X - 1, -(G.HEAD + G.BONUS_H))
  f.line:SetSize(3, G.LANE)
  -- the landing spot: a framed square the notes drop into, not just a line (2026-11-11)
  f.boxes = {}
  local b = f:CreateTexture(nil, "ARTWORK")
  b:SetColorTexture(1, 1, 1, 0.1)
  b:SetSize(G.ICON + 12, G.ICON + 12)
  b:SetPoint("CENTER", f, "TOPLEFT", G.HIT_X, G.LaneY())
  f.boxes[1] = b
  f.frame = {}
  local edge = 4
  for i, side in ipairs({ { "TOPLEFT", "TOPRIGHT", nil, edge }, { "BOTTOMLEFT", "BOTTOMRIGHT", nil, edge },
    { "TOPLEFT", "BOTTOMLEFT", edge, nil }, { "TOPRIGHT", "BOTTOMRIGHT", edge, nil } }) do
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(1, 0.82, 0.25, 0.95)
    t:SetPoint(side[1], b, side[1], 0, 0)
    t:SetPoint(side[2], b, side[2], 0, 0)
    if side[3] then
      t:SetWidth(side[3])
    else
      t:SetHeight(side[4])
    end
    f.frame[i] = t
  end
  -- the lane: a faint centre line and dots that scroll with the notes, so it reads as a track (2026-11-11)
  f.mid = f:CreateTexture(nil, "BORDER")
  f.mid:SetColorTexture(1, 0.85, 0.4, 0.15)
  f.mid:SetPoint("LEFT", f, "TOPLEFT", G.HIT_X, G.LaneY())
  f.mid:SetSize(G.WIDTH - G.HIT_X - 4, 2)
  f.dots = {}
  for i = 1, math.ceil(G.LOOK / G.DOT_EVERY) + 1 do
    local dot = f:CreateTexture(nil, "BORDER", nil, 1)
    dot:SetColorTexture(1, 0.85, 0.4, 0.45)
    dot:SetSize(6, 6)
    f.dots[i] = dot
  end
  -- the action track above the lane: only there while a defensive, interrupt or item waits on it
  f.actTrack = f:CreateTexture(nil, "BACKGROUND", nil, 1)
  f.actTrack:SetColorTexture(0.6, 0.08, 0.06, 0.35)
  f.actTrack:SetPoint("LEFT", f, "TOPLEFT", 0, G.BonusY())
  f.actTrack:SetSize(G.WIDTH, G.BONUS_ICON + 12)
  f.actTrack:SetAlpha(0)
  -- urgent look: red edges and a warning sign at its start, so it never reads like a buff icon
  f.actEdges = {}
  for i, dy in ipairs({ (G.BONUS_ICON + 12) / 2, -(G.BONUS_ICON + 12) / 2 }) do
    local e = f:CreateTexture(nil, "ARTWORK")
    e:SetColorTexture(1, 0.2, 0.15, 0.9)
    e:SetPoint("LEFT", f, "TOPLEFT", 0, G.BonusY() + dy)
    e:SetSize(G.WIDTH, 2)
    e:SetAlpha(0)
    f.actEdges[i] = e
  end
  f.actSign = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.actSign, 26, "THICKOUTLINE")
  f.actSign:SetPoint("CENTER", f, "TOPLEFT", 12, G.BonusY())
  f.actSign:SetTextColor(1, 0.25, 0.2)
  f.actSign:SetText("!")
  f.actSign:SetAlpha(0)
  f.actBox = f:CreateTexture(nil, "ARTWORK")
  f.actBox:SetColorTexture(1, 0.3, 0.25, 0.35)
  f.actBox:SetPoint("CENTER", f, "TOPLEFT", G.HIT_X, G.BonusY())
  f.actBox:SetSize(G.BONUS_ICON + 10, G.BONUS_ICON + 10)
  f.actBox:SetAlpha(0)
  -- the alarm: a red edge around everything
  f.alarm = f:CreateTexture(nil, "BACKGROUND", nil, -1)
  f.alarm:SetColorTexture(1, 0.1, 0.05, 0.8)
  f.alarm:SetPoint("TOPLEFT", f, "TOPLEFT", -6, 6)
  f.alarm:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 6, G.FOOT - 6)
  f.alarm:SetAlpha(0)
  -- your cast in progress: a dim track as long as the cast, a bright bar filling it left to right (2026-11-11)
  f.castTrack = f:CreateTexture(nil, "BORDER", nil, 1)
  f.castTrack:SetHeight(G.BAR_H + 6)
  f.castTrack:Hide()
  f.castFill = f:CreateTexture(nil, "BORDER", nil, 2)
  f.castFill:SetHeight(G.BAR_H + 6)
  f.castFill:Hide()
  -- the arrival burst: a gold square that grows out of the spot and fades
  f.burst = f:CreateTexture(nil, "OVERLAY")
  f.burst:SetColorTexture(1, 0.85, 0.3, 0)
  f.burst:SetPoint("CENTER", b, "CENTER", 0, 0)
  f.burst:SetSize(G.ICON, G.ICON)
  f.streak = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.streak, 20)
  f.streak:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -(G.HEAD + G.BONUS_H + G.LANE + 8))
  f.stars = {}
  f.toggle = G.ToggleButton(f)
  f.toggle:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -(G.HEAD + G.BONUS_H + G.LANE + 7))
  -- the judgement ("Perfect!") over the line, and the streak word ("On fire!") in the middle of the lanes
  f.judge = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.judge, 20)
  f.judge:SetPoint("BOTTOMLEFT", f, "TOPLEFT", G.HIT_X - 12, -(G.HEAD + G.BONUS_H) + 4)
  f.judge:Hide()
  f.pop = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.pop, G.LANE - 12, "THICKOUTLINE") -- almost the whole lane: kudos you can't miss
  f.pop:SetPoint("BOTTOM", f, "TOP", 0, 4) -- above everything: the lane stays readable under it
  f.pop:SetTextColor(1, 0.85, 0.2)
  f.pop:Hide()
  f.slip = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.slip, 16)
  f.slip:SetPoint("TOP", f, "BOTTOMLEFT", G.HIT_X, -2)
  f.slip:SetTextColor(1, 0.55, 0.2)
  -- before a set's first press: an arcade "press start" over the lane (2026-11-11: "like it's waiting for you to
  -- play it"); your first spell starts the Flow
  f.ready = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.ready, 30, "THICKOUTLINE")
  f.ready:SetPoint("CENTER", f, "TOPLEFT", G.HIT_X + G.ICON + (G.WIDTH - G.HIT_X - G.ICON) / 2, G.LaneY() + 10)
  f.ready:SetTextColor(1, 0.85, 0.2)
  f.readySub = f:CreateFontString(nil, "OVERLAY")
  D.SetFont(f.readySub, 13)
  f.readySub:SetPoint("TOP", f.ready, "BOTTOM", 0, -4)
  f.readySub:SetTextColor(1, 1, 1)
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
    s:SetSize(24, 24)
    s:SetPoint("LEFT", f.streak, "RIGHT", 6 + (i - 1) * 25, 0) -- after the streak text, clear of the switch
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
  -- a wrong press: a red X over the note (it stays: press it now)
  n.xmark = n:CreateTexture(nil, "OVERLAY")
  n.xmark:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
  n.xmark:SetPoint("CENTER", n, "CENTER", 0, 0)
  n.xmark:SetSize(G.ICON * 0.8, G.ICON * 0.8)
  n.xmark:Hide()
  -- hold bar: the cast (yellow) or channel (blue) trailing the note
  n.bar = n:CreateTexture(nil, "BACKGROUND", nil, -1)
  n.bar:SetPoint("LEFT", n, "CENTER", 0, 0)
  n.bar:SetHeight(G.BAR_H)
  n.bar:Hide()
  -- the bonus row's call: KICK! / DEFEND! / POWER UP!
  n.tag = n:CreateFontString(nil, "OVERLAY")
  ns.Display.SetFont(n.tag, 13)
  n.tag:SetPoint("BOTTOM", n, "TOP", 0, 2)
  return n
end

-- Where a note wants to be: x of its center for `t` seconds before the line.
local function XFor(t)
  local px = (G.WIDTH - G.HIT_X - G.ICON / 2 - 2) / G.LOOK
  return G.HIT_X + math.max(0, math.min(G.LOOK, t)) * px
end

-- How long pressing this keeps you busy: a channel's duration (spell data "chan", hasted), else its cast time.
function G.HoldTime(id)
  local data = ns.SpellMap.Info and ns.SpellMap.Info(id)
  if data and data.chan and tonumber(data.d) then
    local gcd = ns.State.GCD and ns.State.GCD(id) or 1.5
    local base = tonumber(data.gcd) or 1.5
    return data.d * (gcd / base), "channel" -- hasted like the GCD
  end
  local info = U.Get(C_Spell and C_Spell.GetSpellInfo, id)
  local cast = type(info) == "table" and tonumber(U.Read(info.castTime)) or 0
  if cast and cast > 0 then
    return cast / 1000, "cast"
  end
  return 0, nil
end

-- Your cast or channel running: track = its whole length from the landing spot, fill = how much has passed.
function G.RenderCast(f)
  local S = ns.State
  local id, left = S.CurrentCast()
  if not (id and left and left > 0) then
    G.curCast = nil
    f.castTrack:Hide()
    f.castFill:Hide()
    return
  end
  if not (G.curCast and G.curCast.id == id) then
    G.curCast = { id = id, total = left }
  end
  local total = math.max(G.curCast.total, left)
  G.curCast.total = total
  local px = (G.WIDTH - G.HIT_X - G.ICON / 2 - 2) / G.LOOK
  local width = math.min(total * px, G.WIDTH - G.HIT_X - 4)
  local done = math.max(0, math.min(1, 1 - left / total))
  local channel = S.Channeling() == id
  local r, g, b = 1, 0.85, 0.3
  if channel then
    r, g, b = 0.35, 0.65, 1
  end
  f.castTrack:ClearAllPoints()
  f.castTrack:SetPoint("LEFT", f, "TOPLEFT", G.HIT_X, G.LaneY())
  f.castTrack:SetWidth(math.max(1, width))
  f.castTrack:SetColorTexture(r, g, b, 0.25)
  f.castTrack:Show()
  f.castFill:ClearAllPoints()
  f.castFill:SetPoint("LEFT", f, "TOPLEFT", G.HIT_X, G.LaneY())
  f.castFill:SetWidth(math.max(1, width * done))
  f.castFill:SetColorTexture(math.min(1, r + 0.1), math.min(1, g + 0.1), math.min(1, b + 0.1), 0.9)
  f.castFill:Show()
end

-- A boss mod's big hit coming within the lane's view: { id = the defensive, t = seconds until it should be
-- pressed } (Defensives.Lead before the hit, so it lands on the line exactly when the classic HUD would show it).
function G.IncomingHit()
  local B, F = ns.BossMods, ns.Defensives
  if not (B and B.NextHit and F and F.Spell) or (ns.db and ns.db.defensiveMode == "off") then
    return nil
  end
  local left = B.NextHit("aoe")
  local role = ns.Specs and ns.Specs.current and ns.Specs.current.role
  if role == "TANK" then
    local tank = B.NextHit("role")
    if tank and (not left or tank < left) then
      left = tank
    end
  end
  if not left then
    return nil
  end
  local id = F.Spell(true)
  if not id then
    return nil
  end
  local t = left - F.Lead(id, tonumber(ns.db and ns.db.defensiveLead) or 3)
  if t > G.LOOK then
    return nil
  end
  return { id = id, t = math.max(0, t) }
end

-- Power mode: a haste burst (Bloodlust and the like, State.boost) or a major cooldown just used.
function G.PowerOn()
  local now = GetTime()
  if G.powerUntil and now < G.powerUntil then
    return true
  end
  for _, b in pairs(ns.State.boost or {}) do
    if b.untilT and b.untilT > now then
      return true
    end
  end
  return false
end

-- The notes we want this frame: { key, lane, pick, t, special } in each lane. Keyed by spell (and its place),
-- so a note keeps sliding when the queue moves up (slot 2 becomes slot 1 after a press).
local function Wanted(r, wait)
  local want = {}
  G.listed = {}
  local q = G.queue or {}
  local t = math.max(0, wait or 0)
  local seen = {}
  for i = 1, 3 do
    local p = q[i]
    if p and p.id then
      local k = tostring(p.item or p.id)
      seen[k] = (seen[k] or 0) + 1
      local gcd = (ns.State.GCD and ns.State.GCD(p.id)) or 1.5
      local hold, holdKind = G.HoldTime(p.id)
      local fire = p.major or (ns.Grade and ns.Grade.IsCooldown and ns.Grade.IsCooldown(p)) or nil
      local key = "1:" .. k .. ":" .. seen[k]
      G.listed[key] = true
      if i == 1 or not (G.hidden and G.hidden[key]) then
        want[#want + 1] = { key = key, lane = 1, pick = p, t = t, main = i == 1,
          hold = hold, holdKind = holdKind, fire = fire and true or nil }
      end
      t = t + math.max(gcd, hold)
    end
  end
  -- the bonus row (lane 2): what isn't the rotation, when it's needed
  local bonus = 0
  local function Bonus(entry)
    bonus = bonus + 1
    entry.lane, entry.t, entry.slot = 2, 0, bonus
    want[#want + 1] = entry
  end
  local intr = r.interrupt
  if intr and intr.id and (intr.how == "decided" or intr.how == "render") then
    Bonus({ key = "b:kick", pick = { id = intr.id, source = "interrupt" }, special = "interrupt", intr = intr,
      bonus = "kick", timed = true })
  end
  local d = r.defensive
  local w = r.weave
  local incoming = not (d and d.id) and G.IncomingHit()
  if d and d.id and (d.how == "decided" or d.how == "render") then
    Bonus({ key = "b:def", pick = { id = d.id, source = "defensive" },
      special = d.how == "render" and "health" or "urgent", def = d, bonus = "defend", timed = true })
  elseif incoming then
    -- a boss mod's hit on its way: the defensive scrolls in and lands when it's time to press it
    Bonus({ key = "b:def", pick = { id = incoming.id, source = "defensive" }, special = "urgent", bonus = "defend",
      timed = true })
    want[#want].t = incoming.t
  elseif w and w.id then
    Bonus({ key = "b:" .. tostring(w.id), pick = w, special = w.urgent and "urgent", bonus = "defend" })
  end
  local it = r.trinket
  if it and (it.id or it.item) then
    Bonus({ key = "b:item:" .. tostring(it.item or it.id), pick = it, bonus = "item" })
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

local function Flash(fs, text, color)
  fs:SetText(text)
  if color then
    fs:SetTextColor(color[1], color[2], color[3])
  end
  fs.at = GetTime()
  fs:SetAlpha(1)
  fs:Show()
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
  -- a hidden "next" is back once it's off the queue (or it's slot 1)
  for key in pairs(G.hidden or {}) do
    if not G.listed[key] then
      G.hidden[key] = nil
    end
  end
  local keep = {}
  local actions = 0
  local px = (G.WIDTH - G.HIT_X - G.ICON / 2 - 2) / G.LOOK
  local prevX, prevT -- the lane note before this one
  for _, w in ipairs(want) do
    local n = G.notes[w.key]
    if n and w.lane == 1 and not w.main and prevX then
      -- only slot 1 stands on the line: a note moved back while it waited there drops away
      local minX = prevX + math.max(G.ICON + G.GAP_MIN, (w.t - (prevT or 0)) * px)
      if n.x < minX and n.x < G.HIT_X + G.ICON * 0.75 then
        G.Drop(n, w.key)
        n = nil
      end
    end
    if not n then
      n = table.remove(G.pool or {}) or NewNote(f)
      n.x = G.WIDTH + G.ICON -- slides in from the right
      n.passed, n.readyAt, n.missAt, n.alarmed = 0, nil, nil, nil
      G.notes[w.key] = n
    end
    n.fade = nil -- wanted again: not fading (a stale fade time would drop it at once later)
    keep[w.key] = true
    n.lane, n.main = w.lane, w.main
    D.SetIcon(n, w.pick, cfg, w.main or w.lane > 1, "")
    n.name:SetText("")
    n.label:SetText("")
    n.source:SetText("")
    local y = G.LaneY()
    if w.lane == 2 then
      -- the action track: opens above the lane when something needs doing. Interrupts and defensives slide in
      -- (a boss hit's defensive from as far as its timer) and land on the same line; items wait beside it.
      n:SetSize(G.BONUS_ICON, G.BONUS_ICON)
      if w.timed then
        local target = XFor(w.t)
        if target < n.x then
          n.x = n.x + (target - n.x) * math.min(1, elapsed * G.GLIDE)
          if math.abs(n.x - target) < 0.5 then
            n.x = target
          end
        end
        if w.t <= 0.05 and not n.alarmed then
          n.alarmed = true
          f.alarmAt = now
          G.Kudos(f, L[G.BONUS_TAG[w.bonus]], { 1, 0.25, 0.2 }, true)
        elseif w.t > 0.05 then
          n.alarmed = nil
        end
      else
        n.x = G.HIT_X + (w.slot - 1) * (G.BONUS_ICON + 56)
      end
      actions = actions + 1
      y = G.BonusY()
      local pulse = 0.6 + 0.4 * math.abs(math.sin(now * 4))
      n.tag:SetText(L[G.BONUS_TAG[w.bonus]])
      n.tag:SetTextColor(1, 0.4 + 0.45 * pulse, 0.2)
      n.tag:Show()
    else
      n:SetSize(G.ICON, G.ICON)
      n.tag:Hide()
      -- left, never right: a later target (a new global cooldown, a wrong press) pauses the note where it is.
      -- The one exception keeps the timeline true: a note never closer to the one before it than their real time
      -- apart (and never touching), so two notes side by side always mean "one, then the other".
      local target = XFor(w.t)
      local minX = prevX and (prevX + math.max(G.ICON + G.GAP_MIN, (w.t - (prevT or 0)) * px)) or nil
      if minX and target < minX then
        target = minX
      end
      if target < n.x or (minX and n.x < minX) then
        n.x = n.x + (target - n.x) * math.min(1, elapsed * G.GLIDE)
        if math.abs(n.x - target) < 0.5 then
          n.x = target
        end
      end
      prevX, prevT = n.x, w.t
      if w.main then
        n.passed = 0
        if G.hidden then
          G.hidden[w.key] = nil
        end
        -- waiting on the line with you free to press it: the clock for a quiet miss
        if w.t <= 0.05 then
          n.readyAt = n.readyAt or now
        else
          n.readyAt = nil
        end
      else
        n.readyAt = nil
      end
    end
    local shake = 0
    if n.missAt and now - n.missAt < G.MISS_SHOW then
      n.xmark:Show()
      shake = 4 * math.sin((now - n.missAt) * 50)
    else
      n.xmark:Hide()
      n.missAt = nil
    end
    n:ClearAllPoints()
    n:SetPoint("CENTER", f, "TOPLEFT", n.x + shake, y)
    if w.main then
      G.mainNote = n
    end
    n.fire = w.fire
    if w.lane == 1 and w.hold and w.hold > 0 then
      n.bar:SetWidth(math.max(4, w.hold * px))
      if w.holdKind == "channel" then
        n.bar:SetColorTexture(0.3, 0.6, 1, 0.75)
      else
        n.bar:SetColorTexture(1, 0.85, 0.3, 0.6)
      end
      n.bar:Show()
    else
      n.bar:Hide()
    end
    local c = G.LANE_COLOR[1]
    if w.fire and w.lane == 1 then
      -- a flame note: worth double, burns orange
      n.edge:SetColorTexture(1, 0.35 + 0.3 * math.abs(math.sin(now * 6)), 0.05, 0.95)
    elseif w.special == "interrupt" then
      n.edge:SetColorTexture(1, 0.85, 0.2, 0.9)
    elseif w.special == "urgent" or w.special == "health" then
      n.edge:SetColorTexture(1, 0.25, 0.25, 0.4 + 0.5 * math.abs(math.cos(now * math.pi * 1.5)))
    else
      n.edge:SetColorTexture(c[1], c[2], c[3], (w.main and w.t <= 0.05) and 0.95 or 0.35)
    end
    n:SetAlpha((w.main or w.lane == 2) and 1 or 0.75)
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
      local a = 1 - (now - n.fade) / 0.2
      if a <= 0 then
        n:Hide()
        G.notes[key] = nil
        G.pool = G.pool or {}
        G.pool[#G.pool + 1] = n
      else
        n:SetAlpha(a * 0.6)
        -- swapped out: it drops away below the lane, so it never sits on top of the note arriving
        local drop = (1 - a) * G.LANE * 0.6
        n:SetPoint("CENTER", f, "TOPLEFT", n.x, (n.lane == 2 and G.BonusY() or G.LaneY()) - drop)
      end
    end
  end
  -- dropped from the line: it falls away (red when it counted as a miss)
  for i = #(G.dropping or {}), 1, -1 do
    local n = G.dropping[i]
    local a = 1 - (now - n.fade) / 0.35
    if a <= 0 then
      n:Hide()
      table.remove(G.dropping, i)
      G.pool = G.pool or {}
      G.pool[#G.pool + 1] = n
    else
      n:SetAlpha(a * 0.8)
      if n.dropMiss then
        n.edge:SetColorTexture(1, 0.2, 0.2, a)
      end
      n:ClearAllPoints()
      n:SetPoint("CENTER", f, "TOPLEFT", n.x, G.LaneY() - (1 - a) * G.LANE * 0.7)
    end
  end
  -- the action track shows only while something's on it
  G.actAlpha = (G.actAlpha or 0) + ((actions > 0 and 1 or 0) - (G.actAlpha or 0)) * math.min(1, elapsed * 10)
  local beat = 0.6 + 0.4 * math.abs(math.sin(now * 5))
  f.actTrack:SetAlpha(G.actAlpha)
  f.actBox:SetAlpha(G.actAlpha * beat)
  f.actSign:SetAlpha(G.actAlpha * beat)
  for _, e in ipairs(f.actEdges) do
    e:SetAlpha(G.actAlpha)
  end
  -- the alarm: the whole frame's edge flashes red when a defensive or interrupt lands
  local al = f.alarmAt and (1 - (now - f.alarmAt) / 1.2) or 0
  f.alarm:SetAlpha(al > 0 and (0.4 + 0.6 * math.abs(math.sin(now * 12))) * al or 0)
  -- the lane's dots: one every DOT_EVERY seconds, scrolling with the notes (eaten at the line)
  local phase = now % G.DOT_EVERY
  for i, dot in ipairs(f.dots) do
    local x = G.HIT_X + ((i - 1) * G.DOT_EVERY + G.DOT_EVERY - phase) * px
    if x > G.HIT_X + G.ICON / 2 and x < G.WIDTH - 4 then
      dot:ClearAllPoints()
      dot:SetPoint("CENTER", f, "TOPLEFT", x, G.LaneY())
      dot:Show()
    else
      dot:Hide()
    end
  end
  -- pressed notes: a quick burst where they were hit
  for i = #(G.fading or {}), 1, -1 do
    local n = G.fading[i]
    local a = 1 - (now - n.fade) / 0.3
    if a <= 0 then
      n:Hide()
      table.remove(G.fading, i)
      G.pool = G.pool or {}
      G.pool[#G.pool + 1] = n
    else
      n:SetAlpha(a)
      n:SetSize(G.ICON * (1 + (1 - a) * 0.6), G.ICON * (1 + (1 - a) * 0.6))
    end
  end
  G.RenderCast(f)
  local power = G.PowerOn()
  if power then
    local p2 = 0.5 + 0.5 * math.abs(math.sin(now * 3))
    f.lane:SetColorTexture(0.2, 0.5, 1, 0.18 + 0.12 * p2)
    f.line:SetColorTexture(0.4, 0.8, 1, 1)
    f.bg:SetColorTexture(0.02, 0.05, 0.14, 0.7)
  else
    f.lane:SetColorTexture(1, 0.8, 0.3, 0.08)
    f.line:SetColorTexture(1, 0.82, 0.25, 0.9)
    f.bg:SetColorTexture(0.04, 0.04, 0.07, 0.55)
  end
  if power and not G.powerShown then
    G.powerShown = true
    G.Kudos(f, L["POWER MODE!"], { 0.4, 0.8, 1 }, true)
  elseif not power then
    G.powerShown = nil
  end
  local fl = f.flashAt and (1 - (now - f.flashAt) / G.FLASH) or 0
  if fl > 0 then
    f.boxes[1]:SetColorTexture(1, 0.85, 0.3, 0.25 + 0.7 * fl)
    local grow = G.ICON * (1 + (1 - fl) * 1.2)
    f.burst:SetSize(grow, grow)
    f.burst:SetColorTexture(1, 0.85, 0.3, 0.6 * fl)
  else
    f.boxes[1]:SetColorTexture(1, 1, 1, 0.1)
    f.burst:SetColorTexture(1, 0.85, 0.3, 0)
  end
  for _, t in ipairs(f.frame) do
    t:SetAlpha(G.PowerOn() and 0.6 or (0.75 + 0.25 * fl))
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
  G.RenderReady(f, now)
  RenderStreak(f)
end

-- "Press start": out of combat with nothing played yet this set. A fresh headline each time it comes up.
G.READY_WORDS = { "READY, PLAYER ONE?", "INSERT COIN", "PRESS START" }
function G.RenderReady(f, now)
  local fight = UnitAffectingCombat and UnitAffectingCombat("player")
  local waiting = not fight and G.hits == 0 and G.score == 0
  if not waiting then
    G.readyWord = nil
    f.ready:Hide()
    f.readySub:Hide()
    return
  end
  if not G.readyWord then
    G.readyWord = G.READY_WORDS[math.random(#G.READY_WORDS)]
  end
  local pulse = 0.55 + 0.45 * math.abs(math.sin(now * 2.5))
  f.ready:SetText(L[G.readyWord])
  f.ready:SetAlpha(pulse)
  f.ready:Show()
  f.readySub:SetText(L["Hit your first spell to start the Flow"])
  f.readySub:Show()
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

-- A hit: the pressed note bursts at the line and the ones behind keep sliding (a second note of the same spell
-- becomes the first, it doesn't jump).
local function Consume(note)
  if not note or note.fade then
    return -- already going (a note goes back to the pool once: twice would put one frame under two notes)
  end
  local hitID
  for key, n in pairs(G.notes) do
    if n == note then
      G.notes[key] = nil
      hitID = key:match("^1:(.-):%d+$")
    end
  end
  note.fade = GetTime()
  G.fading = G.fading or {}
  G.fading[#G.fading + 1] = note
  if hitID then
    local moved = {}
    for key, n in pairs(G.notes) do
      local id, k = key:match("^1:(.-):(%d+)$")
      if id == hitID and tonumber(k) > 1 then
        moved[id .. ":" .. (tonumber(k) - 1)] = n
        G.notes[key] = nil
      end
    end
    for key, n in pairs(moved) do
      G.notes["1:" .. key] = n
    end
  end
  -- every other lane note was passed over once; one the engine keeps putting off goes out of sight
  for key, n in pairs(G.notes) do
    if key:sub(1, 2) == "1:" then
      n.passed = (n.passed or 0) + 1
      if n.passed >= G.PASS_MAX and n ~= G.mainNote then
        G.hidden = G.hidden or {}
        G.hidden[key] = true
      end
    end
  end
end
G.Consume = Consume

-- A note leaves the line without a press (the engine moved it back): it falls away; a miss if it waited there.
function G.Drop(n, key)
  if G.notes[key] == n then
    G.notes[key] = nil
  end
  local missed = n.readyAt and GetTime() - n.readyAt >= G.EXPIRE
  n.fade = GetTime()
  n.dropMiss = missed or nil
  n.readyAt = nil
  G.dropping = G.dropping or {}
  G.dropping[#G.dropping + 1] = n
  if G.mainNote == n then
    G.mainNote = nil
  end
  if missed then
    G.QuietMiss()
  end
end

-- A note that ran out of time: the streak breaks and the set's Perfect share counts it, without the shake.
function G.QuietMiss()
  G.Break()
  G.perfectRun = 0
  G.misses = (G.misses or 0) + 1
  G.lastJudge = "miss"
  if G.frame then
    Flash(G.frame.judge, L[G.JUDGE_WORD.miss], G.JUDGE_COLOR.miss)
  end
end

-- From the grade, for each press it judges: "hit" (slot 1), "near" (slot 2 or 3), "miss" (anything else).
-- The lane note for a spell: its first note (the one at the line), else the note slot 1 had.
local function NoteFor(id)
  local baseOf = ns.SpellMap.baseOf or {}
  for key, n in pairs(G.notes) do
    local nid, k = key:match("^1:(%d+):(%d+)$")
    if k == "1" and tonumber(nid) and (baseOf[tonumber(nid)] or tonumber(nid)) == (baseOf[id] or id) then
      return n
    end
  end
  return G.mainNote
end

-- How close to the line a press came: early (queued) presses count from the note still sliding in.
local function Timing()
  local arrived = G.arrived and G.arrived.at
  local wait = (ns.Display.frame and ns.Display.frame.lastWait or 0) - G.Offset()
  local off = arrived and (GetTime() - arrived) or -wait
  if math.abs(off) <= G.PERFECT then
    return "perfect"
  elseif math.abs(off) <= G.GREAT then
    return "great"
  end
  return "good"
end

-- A big word over the lane, for moments that earn it - never every press (2026-11-11: "too often, it's noise").
G.KUDOS_GAP = 5
local function Kudos(f, text, color, force)
  local now = GetTime()
  if not force and G.kudosAt and now - G.kudosAt < G.KUDOS_GAP then
    return
  end
  G.kudosAt = now
  Flash(f.pop, text, color or { 1, 0.85, 0.2 })
end
G.Kudos = Kudos

-- A cast begins: its note bursts at the line now, timed now (its cast event only comes when the bar ends).
function G.OnCastStart(id)
  if not G.On() or not id then
    return
  end
  local note = NoteFor(id)
  if not note or note.lane ~= 1 then
    return
  end
  G.cast = { id = id, at = GetTime(), judge = Timing(), fire = note.fire, color = note }
  Consume(note)
  if note == G.mainNote then
    G.mainNote = nil
  end
  G.arrived = nil
end

function G.OnJudged(kind, id)
  if not G.On() then
    return
  end
  local f = G.Create()
  local judge
  local baseOf = ns.SpellMap.baseOf or {}
  if kind == "miss" then
    judge = "miss"
    G.Break()
    G.perfectRun = 0
    if G.mainNote then
      G.mainNote.missAt = GetTime() -- the note shakes with a red X and stays: press it now
    end
  else
    local fire
    local first = G.hits == 0 and G.score == 0 -- the set's first hit: the Flow starts
    local c = G.cast
    if kind == "hit" and c and id and (baseOf[c.id] or c.id) == (baseOf[id] or id) and GetTime() - c.at < 10 then
      judge, fire = c.judge, c.fire -- judged when the cast began
      G.cast = nil
    elseif kind == "near" then
      judge = "good"
    else
      judge = Timing()
      local note = id and NoteFor(id) or G.mainNote
      fire = note and note.fire
      if kind == "hit" then
        Consume(note)
        if note == G.mainNote then
          G.mainNote = nil
        end
      end
    end
    G.streak = G.streak + 1
    G.hits = G.hits + 1
    if judge == "perfect" then
      G.perfects = G.perfects + 1
      G.perfectRun = (G.perfectRun or 0) + 1
    else
      G.perfectRun = 0
    end
    local points = G.POINTS[judge] * G.Mult()
    if fire then
      points = points * G.FIRE_MULT
      G.powerUntil = GetTime() + G.POWER_TIME -- a major cooldown lands: power mode
    end
    if G.PowerOn() then
      points = points * G.POWER_MULT
    end
    G.score = G.score + points
    G.setBest = math.max(G.setBest, G.streak)
    G.arrived = nil -- the next note's arrival is timed afresh
    local milestone
    for i, m in ipairs(G.MILESTONES) do
      if G.streak == m then
        G.stars = i
        milestone = m
      end
    end
    if first then
      Kudos(f, L["LET'S GO!"], { 0.4, 1, 0.5 }, true)
    elseif milestone then
      Kudos(f, L[G.WORDS[milestone]], nil, true)
    elseif fire then
      Kudos(f, L["Blazing!"], { 1, 0.5, 0.1 }, true)
    elseif G.perfectRun > 0 and G.perfectRun % 5 == 0 then
      Kudos(f, string.format(L["PERFECT x%d"], G.perfectRun), G.JUDGE_COLOR.perfect)
    elseif judge ~= "good" and G.streak % 12 == 0 then
      Kudos(f, Phrase(G.PHRASES[judge]), G.JUDGE_COLOR[judge])
    end
    if G.streak > G.Best() then
      SaveBest()
    end
  end
  G.lastJudge = judge
  -- every press: the small word at the line (colour = how close), the big ones above are for moments
  Flash(f.judge, L[G.JUDGE_WORD[judge]], G.JUDGE_COLOR[judge])
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
    perfect = G.hits > 0 and math.floor(100 * G.perfects / (G.hits + (G.misses or 0)) + 0.5) or 0,
    misses = G.misses or 0 }
  G.score, G.setBest, G.hits, G.perfects, G.misses = 0, 0, 0, 0, 0
  G.streak, G.stars = 0, 0
  return out
end

-- A bonus grabbed (an interrupt, defensive, trinket or potion from the bonus row): it adds to the streak.
function G.OnBonus(kind)
  if not G.On() then
    return
  end
  local f = G.Create()
  G.streak = G.streak + 1
  G.hits = G.hits + 1
  G.setBest = math.max(G.setBest, G.streak)
  local points = G.BONUS_POINTS * G.Mult()
  G.score = G.score + points
  if G.streak > G.Best() then
    SaveBest()
  end
  G.lastJudge = "bonus"
  Kudos(f, L[G.BONUS_DONE[kind] or "Powered up!"] .. "  " .. string.format(L["Bonus +%d"], points),
    { 1, 0.7, 0.2 }, true)
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
  local msg = L["Flow mode off: the classic HUD is back."]
  if on then
    msg = L["Flow mode on: hit each note as it reaches the line. Click the CLASSIC / FLOW switch (or /dmga flow) "
      .. "to switch back."]
  end
  U.Print("%s", msg)
  if not on and G.frame then
    G.frame:Hide()
  end
  if ns.Update then
    ns.Update()
  end
end
