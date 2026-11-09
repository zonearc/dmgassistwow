-- Grade.lua: how well you played a fight, graded at the end of it (S+ to D), with four parts:
--   Accuracy      each press (of a spell that uses the global cooldown) against what slot 1 showed then: the
--                 spell in slot 1 = 1, the one in slot 2 or 3 = 0.5, anything else = 0. Interrupts, defensives,
--                 trinkets and potions from their own icons don't count either way.
--   Always be casting  share of the fight NOT spent with slot 1 ready ("press now") and nothing pressed.
--   Reaction      from the moment slot 1 said "press now" to your press of that spell (pressed early and queued
--                 counts as instant). 150 ms or less is full marks, 1 s or more is none.
--   Cooldowns     how quickly major cooldowns, trinkets and the potion were used once slot 1 or the items icon
--                 showed them ready; one shown and never used before the fight ended counts as very late.
-- Overall: 35% accuracy, 25% always be casting, 20% reaction, 20% cooldowns. It never claims damage: addons can't
-- read the combat log in Midnight, and damage depends on gear; the game's damage meter shows that.
-- Saved account-wide per spec: the best grade and the last 20 fights (DMGAssistDB global grades).

local _, ns = ...
local U, L = ns.U, ns.L

local Gr = {}
ns.Grade = Gr

Gr.WEIGHTS = { accuracy = 0.35, abc = 0.25, reaction = 0.20, cooldowns = 0.20 }
Gr.LETTERS = { { 97, "S+" }, { 92, "S" }, { 85, "A" }, { 75, "B" }, { 65, "C" }, { 0, "D" } }
Gr.COLORS = { ["S+"] = { 1, 0.82, 0.2 }, S = { 1, 0.55, 0.1 }, A = { 0.75, 0.45, 1 }, B = { 0.3, 0.65, 1 },
  C = { 0.35, 0.85, 0.35 }, D = { 0.65, 0.65, 0.65 } }
Gr.HISTORY = 20
Gr.MIN_FIGHT = 20

local fight -- the fight being graded

local function DB()
  local g = ns.global or ns.db
  if type(g) ~= "table" then
    return nil
  end
  g.grades = type(g.grades) == "table" and g.grades or {}
  return g.grades
end

local function SpecKey()
  return ns.Specs.current and ns.Specs.current.key or "?"
end
Gr.SpecKey = SpecKey

function Gr.Enabled()
  return not (ns.db and ns.db.grade == false)
end

local function Base(id)
  return (ns.SpellMap.baseOf and ns.SpellMap.baseOf[id]) or id
end

local function Same(a, b)
  return a ~= nil and b ~= nil and (a == b or Base(a) == Base(b))
end

---------------------------------------------------------------------------
-- During the fight
---------------------------------------------------------------------------
function Gr.OnCombat(on)
  if on then
    fight = { start = GetTime(), presses = 0, score = 0, reactions = {}, idle = 0, lastTick = nil,
      ready = nil, cds = {}, cdShown = {}, missed = {}, instead = {}, targets = 0 }
    return
  end
  local f = fight
  fight = nil
  if f and Gr.Enabled() then
    local r = Gr.Finish(f, GetTime())
    if r then
      Gr.Show(r)
    end
  end
end

-- Display: slot 1 says "press now" for this spell.
function Gr.OnReady(id, now, main)
  local f = fight
  if not f or not id then
    return
  end
  if not (f.ready and Same(f.ready.id, id)) then
    f.ready = { id = id, t = now }
  end
  if main and main.major and not f.cdShown[Base(id)] then
    f.cdShown[Base(id)] = now
  end
end

-- Every frame while the HUD shows: count the time slot 1 was ready and nothing was pressed.
function Gr.Tick(pressNow)
  local f = fight
  if not f then
    return
  end
  local now = GetTime()
  if f.lastTick and pressNow and f.wasReady then
    f.idle = f.idle + math.min(0.25, now - f.lastTick)
  elseif not pressNow then
    f.ready = nil -- reaction is timed from the latest "press now", not an earlier one
  end
  f.lastTick, f.wasReady = now, pressNow
  local t = ns.last and ns.last.trinket
  local key = t and (t.item or t.id)
  if key and not f.cdShown["item:" .. tostring(key)] then
    f.cdShown["item:" .. tostring(key)] = now
  end
  f.targets = math.max(f.targets, tonumber((ns.State.Targets())) or 0)
end

local function IsOffGCD(id)
  local info = ns.SpellMap.Info(id)
  return info and (info.gcd == nil or info.gcd == 0) or false
end

-- Every cast of yours: r = the recommendation that was showing; press = it was a button press (Main.lua IsPress:
-- one per press, and only spells you know, so item uses are never presses).
function Gr.OnPress(id, r, press)
  local f = fight
  if not (f and id and r) then
    return
  end
  local now = GetTime()
  -- items and the staying-alive icon: cooldown use, never accuracy
  local t = r.trinket
  if t and Same(t.id, id) then
    local key = "item:" .. tostring(t.item or t.id)
    if f.cdShown[key] then
      f.cds[#f.cds + 1] = now - f.cdShown[key]
      f.cdShown[key] = nil
    end
    return
  end
  if not press or (r.weave and Same(r.weave.id, id)) then
    return
  end
  local main = r.main
  local queue = r.queue or { main }
  local matched = main and Same(main.id, id)
  if matched or not IsOffGCD(id) then
    f.presses = f.presses + 1
    if matched then
      f.score = f.score + 1
    elseif (queue[2] and Same(queue[2].id, id)) or (queue[3] and Same(queue[3].id, id)) then
      f.score = f.score + 0.5
    else
      local want = main and (main.token or tostring(main.id))
      if want then
        f.missed[want] = (f.missed[want] or 0) + 1
      end
    end
  end
  if matched and f.ready and Same(f.ready.id, id) then
    f.reactions[#f.reactions + 1] = math.max(0, now - f.ready.t)
    f.ready = nil
  end
  local key = Base(id)
  if f.cdShown[key] then
    f.cds[#f.cds + 1] = now - f.cdShown[key]
    f.cdShown[key] = nil
  end
end

---------------------------------------------------------------------------
-- The grade
---------------------------------------------------------------------------
local function Pct(v)
  return v and string.format("%d%%", math.floor(v + 0.5)) or "-"
end

local function Clamp(x)
  return math.max(0, math.min(100, x))
end

function Gr.Letter(score)
  for _, l in ipairs(Gr.LETTERS) do
    if score >= l[1] then
      return l[2]
    end
  end
  return "D"
end

local function Median(list)
  if #list == 0 then
    return nil
  end
  local t = {}
  for i, v in ipairs(list) do
    t[i] = v
  end
  table.sort(t)
  return t[math.floor((#t + 1) / 2)]
end

-- Reaction (seconds) to a score: 0.15 s or less = 100, 1 s or more = 0, straight in between.
function Gr.ReactionScore(sec)
  if not sec then
    return nil
  end
  return Clamp(100 - (sec - 0.15) / 0.85 * 100)
end

-- Cooldown delay (seconds) to a score: within 1 s = 100, 6 s or more = 0.
function Gr.DelayScore(sec)
  return Clamp(100 - (sec - 1) / 5 * 100)
end

function Gr.Finish(f, now)
  local length = now - f.start
  if length < (tonumber(ns.db and ns.db.gradeMinFight) or Gr.MIN_FIGHT) or f.presses < 5 then
    return nil
  end
  for _, shownAt in pairs(f.cdShown) do
    if now - shownAt > 3 then
      f.cds[#f.cds + 1] = math.max(6, now - shownAt) -- shown, never used
    end
  end
  local accuracy = Clamp(f.score / f.presses * 100)
  local abc = Clamp(100 - f.idle / length * 100)
  local reactionSec = Median(f.reactions)
  local reaction = Gr.ReactionScore(reactionSec)
  local cd
  if #f.cds > 0 then
    local sum = 0
    for _, d in ipairs(f.cds) do
      sum = sum + Gr.DelayScore(d)
    end
    cd = sum / #f.cds
  end
  local parts = { accuracy = accuracy, abc = abc, reaction = reaction, cooldowns = cd }
  local total, weight = 0, 0
  for k, w in pairs(Gr.WEIGHTS) do
    if parts[k] then
      total, weight = total + parts[k] * w, weight + w
    end
  end
  local score = weight > 0 and total / weight or 0
  local r = { score = score, letter = Gr.Letter(score), accuracy = accuracy, abc = abc, reaction = reaction,
    reactionMs = reactionSec and math.floor(reactionSec * 1000 + 0.5), cooldowns = cd, length = length,
    idle = f.idle, presses = f.presses, targets = f.targets, at = _G.time and _G.time() or 0 }
  -- the tip: the weakest part
  local weakest, low = nil, 101
  for k in pairs(Gr.WEIGHTS) do
    if parts[k] and parts[k] < low then
      weakest, low = k, parts[k]
    end
  end
  local topMissed, n = nil, 0
  for want, c in pairs(f.missed) do
    if c > n then
      topMissed, n = want, c
    end
  end
  r.weakest, r.topMissed, r.topMissedCount = weakest, topMissed, n
  Gr.Save(r)
  U.Log("grade", { letter = r.letter, score = string.format("%.1f", score), accuracy = math.floor(accuracy),
    abc = math.floor(abc), reaction = r.reactionMs, cooldowns = cd and math.floor(cd), length = math.floor(length) })
  return r
end

function Gr.Tip(r)
  if r.weakest == "accuracy" then
    if r.topMissed then
      local name = r.topMissed:gsub("_", " ")
      return string.format(L["Tip: slot 1 asked for %s %d times when you pressed something else."], name,
        r.topMissedCount)
    end
    return L["Tip: press what slot 1 shows; slots 2 and 3 are what comes after it."]
  elseif r.weakest == "abc" then
    return string.format(L["Tip: slot 1 was ready for %.1f s without a press. Keep the global cooldown rolling."],
      r.idle)
  elseif r.weakest == "reaction" then
    return L["Tip: press as the flash comes, or a little before: the game queues a press made just before it's ready."]
  elseif r.weakest == "cooldowns" then
    return L["Tip: use major cooldowns, trinkets and your potion as soon as they show."]
  end
  return L["Nothing to improve: keep it up."]
end

---------------------------------------------------------------------------
-- Saved results
---------------------------------------------------------------------------
function Gr.Save(r)
  local db = DB()
  if not db then
    return
  end
  local key = SpecKey()
  local s = type(db[key]) == "table" and db[key] or { history = {} }
  db[key] = s
  s.history = type(s.history) == "table" and s.history or {}
  table.insert(s.history, 1, { score = r.score, letter = r.letter, accuracy = r.accuracy, abc = r.abc,
    reaction = r.reaction, reactionMs = r.reactionMs, cooldowns = r.cooldowns, at = r.at, targets = r.targets,
    weakest = r.weakest, idle = r.idle, length = r.length, topMissed = r.topMissed, topMissedCount = r.topMissedCount })
  while #s.history > Gr.HISTORY do
    table.remove(s.history)
  end
  if not s.best or r.score > s.best.score then
    r.newBest = s.best ~= nil
    s.best = { score = r.score, letter = r.letter, at = r.at }
  end
end

function Gr.Summary(key)
  local db = DB()
  local s = db and db[key or SpecKey()]
  return type(s) == "table" and s or nil
end

-- key = one spec's results (nil = every spec's).
function Gr.Reset(key)
  local db = DB()
  if not db then
    return
  end
  if key then
    db[key] = nil
  else
    for k in pairs(db) do
      db[k] = nil
    end
  end
end

-- The report on the settings page, for the spec you are in: best, the trend of the last 10 fights, the average of
-- each part, and where to improve. Returns text lines (nil when no fight was graded yet).
Gr.TREND_FIGHTS = 10
local function Colored(letter)
  local c = Gr.COLORS[letter] or Gr.COLORS.D
  return string.format("|cff%02x%02x%02x%s|r", c[1] * 255, c[2] * 255, c[3] * 255, letter)
end
Gr.Colored = Colored

local function Average(list, field, from, to)
  local sum, n = 0, 0
  for i = from, math.min(to, #list) do
    local v = list[i][field]
    if type(v) == "number" then
      sum, n = sum + v, n + 1
    end
  end
  return n > 0 and sum / n or nil
end

function Gr.Report(key)
  local s = Gr.Summary(key)
  local h = s and s.history
  if not (h and #h > 0) then
    return nil
  end
  local lines = {}
  local fmtDate = _G.date
  if s.best then
    lines[#lines + 1] = string.format("|cffffd100%s|r  %s  %.1f%s", L["Best"], Colored(s.best.letter), s.best.score,
      (fmtDate and s.best.at and s.best.at > 0) and ("  (" .. fmtDate("%Y-%m-%d", s.best.at) .. ")") or "")
  end
  local n = math.min(#h, Gr.TREND_FIGHTS)
  local row = {}
  for i = n, 1, -1 do -- oldest first, newest last
    row[#row + 1] = Colored(h[i].letter or "D")
  end
  lines[#lines + 1] = string.format("|cffffd100%s|r  %s", string.format(L["Last %d fights (newest last)"], n),
    table.concat(row, " "))
  if #h >= 6 then
    local recent, before = Average(h, "score", 1, 3), Average(h, "score", 4, 10)
    local word = L["steady"]
    if recent and before and recent - before >= 3 then
      word = "|cff33dd33" .. L["improving"] .. "|r"
    elseif recent and before and before - recent >= 3 then
      word = "|cffff6060" .. L["slipping"] .. "|r"
    end
    lines[#lines + 1] = string.format("|cffffd100%s|r  %s", L["Trend"], word)
  end
  local avg = {
    accuracy = Average(h, "accuracy", 1, n), abc = Average(h, "abc", 1, n), reaction = Average(h, "reaction", 1, n),
    cooldowns = Average(h, "cooldowns", 1, n),
  }
  local ms = Average(h, "reactionMs", 1, n)
  lines[#lines + 1] = string.format("|cffffd100%s|r  %s %s   %s %s   %s %s   %s %s",
    string.format(L["Average of the last %d"], n), L["Accuracy"], Pct(avg.accuracy), L["Always casting"],
    Pct(avg.abc), L["Reaction"], ms and (math.floor(ms + 0.5) .. " ms") or "-", L["Cooldowns"], Pct(avg.cooldowns))
  -- where to improve: the weakest part on average, with the most-missed spell of the latest fight that had one
  local weakest, low = nil, 101
  for k in pairs(Gr.WEIGHTS) do
    if avg[k] and avg[k] < low then
      weakest, low = k, avg[k]
    end
  end
  local tip = { weakest = low < 90 and weakest or nil, idle = Average(h, "idle", 1, n) or 0 }
  for i = 1, n do
    if h[i].topMissed then
      tip.topMissed, tip.topMissedCount = h[i].topMissed, h[i].topMissedCount or 1
      break
    end
  end
  lines[#lines + 1] = string.format("|cffffd100%s|r  %s", L["Where to improve"], Gr.Tip(tip))
  return lines
end

---------------------------------------------------------------------------
-- The popup
---------------------------------------------------------------------------
Gr.SHOW_SECONDS = 6
local FADE_IN, FADE_OUT = 0.15, 0.8

local function Place(f)
  f:ClearAllPoints()
  local pos = ns.db and type(ns.db.gradePoint) == "table" and ns.db.gradePoint
  if pos then
    f:SetPoint(pos[1] or "CENTER", UIParent, pos[2] or "CENTER", tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
  elseif ns.Display.frame then
    f:SetPoint("BOTTOM", ns.Display.frame, "TOP", 0, 24)
  else
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 80)
  end
end

function Gr.ResetPosition()
  if Gr.frame then
    Place(Gr.frame)
  end
end

local function Frame()
  if Gr.frame then
    return Gr.frame
  end
  local f = CreateFrame("Frame", "DMGAssistGrade", UIParent)
  f:SetSize(300, 96)
  f:SetFrameStrata("HIGH")
  Place(f)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(self)
    if (ns.db and ns.db.locked == false) or (ns.Integrations and ns.Integrations.editMode) then
      self:StartMoving()
    end
  end)
  f:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local p1, _, p2, x, y = self:GetPoint()
    if ns.db then
      ns.db.gradePoint = { p1, p2, x, y }
    end
  end)
  f.letter = f:CreateFontString(nil, "OVERLAY")
  f.letter:SetPoint("LEFT", f, "LEFT", 4, 6)
  f.title = f:CreateFontString(nil, "OVERLAY")
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 74, -6)
  f.parts = f:CreateFontString(nil, "OVERLAY")
  f.parts:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -6)
  f.parts:SetJustifyH("LEFT")
  f.tip = f:CreateFontString(nil, "OVERLAY")
  f.tip:SetPoint("TOPLEFT", f.parts, "BOTTOMLEFT", 0, -6)
  f.tip:SetWidth(320)
  f.tip:SetJustifyH("LEFT")
  f:Hide()
  f:SetScript("OnUpdate", function(self)
    if self.sample then
      self:SetAlpha(1)
      return
    end
    local t = GetTime() - (self.shownAt or 0)
    local hold = tonumber(ns.db and ns.db.gradeSeconds) or Gr.SHOW_SECONDS
    if t < FADE_IN then
      self:SetAlpha(t / FADE_IN)
    elseif t < FADE_IN + hold then
      self:SetAlpha(1)
    elseif t < FADE_IN + hold + FADE_OUT then
      self:SetAlpha(1 - (t - FADE_IN - hold) / FADE_OUT)
    else
      self:Hide()
    end
  end)
  Gr.frame = f
  return f
end

function Gr.Render(r, sample, test)
  local f = Frame()
  local D = ns.Display
  local c = Gr.COLORS[r.letter] or Gr.COLORS.D
  D.SetFont(f.letter, 54)
  f.letter:SetText(r.letter)
  f.letter:SetTextColor(c[1], c[2], c[3])
  D.SetFont(f.title, 15)
  f.title:SetText(string.format("%s  |cffffffff%.1f|r%s", L["Fight grade"], r.score,
    r.newBest and ("  |cffffd100" .. L["New best!"] .. "|r") or ""))
  f.title:SetTextColor(c[1], c[2], c[3])
  D.SetFont(f.parts, 12)
  f.parts:SetText(string.format("%s %s   %s %s   %s %s   %s %s", L["Accuracy"], Pct(r.accuracy),
    L["Always casting"], Pct(r.abc), L["Reaction"], r.reactionMs and (r.reactionMs .. " ms") or "-",
    L["Cooldowns"], Pct(r.cooldowns)))
  D.SetFont(f.tip, 11)
  f.tip:SetText(Gr.Tip(r))
  f.tip:SetTextColor(0.85, 0.85, 0.85)
  f.sample = sample
  f.shownAt = GetTime()
  f:EnableMouse((ns.db and ns.db.locked == false) or (ns.Integrations and ns.Integrations.editMode) or false)
  f:SetAlpha(sample and 1 or 0)
  f:Show()
  if not (sample or test) then
    Gr.last = r
  end
end

function Gr.Show(r)
  Gr.Render(r, false)
end

-- Settings button: the sample, popping up and fading like a real grade.
function Gr.Test()
  Gr.Render(Gr.SAMPLE, false, true)
end

Gr.SAMPLE = { score = 93.4, letter = "S", accuracy = 96, abc = 91, reaction = 88, reactionMs = 245, cooldowns = 95,
  weakest = "reaction", idle = 3.2 }

-- In Edit Mode, while unlocked or on the grade's settings page: a sample to place and size it.
function Gr.ShowSample(on)
  if on then
    Gr.Render(Gr.SAMPLE, true)
  elseif Gr.frame and Gr.frame.sample then
    Gr.frame.sample = false
    Gr.frame:Hide()
  end
end

-- The sample shows while the grade can be placed: in Edit Mode or with the HUD unlocked.
function Gr.SyncSample()
  local I = ns.Integrations
  local on = Gr.Enabled() and ((ns.db and ns.db.locked == false) or (I and I.editMode)) or false
  if on then
    Gr.ShowSample(true)
  elseif Gr.frame and Gr.frame.sample then
    Gr.ShowSample(false)
  end
end
