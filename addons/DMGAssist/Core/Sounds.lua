-- Sounds.lua: audio alerts. One sound per event, chosen in Options > Alerts & Sounds; each event is throttled.
-- Sounds are Blizzard's own sound kits (SOUNDKIT names exist on forever and live; numeric fallbacks from
-- Blizzard_SharedXML/Mainline/SoundKitConstants.lua), played on the Master channel so they cut through music.

local _, ns = ...
local U = ns.U

local S = {}
ns.Sounds = S

S.CHOICES = {
  { "none", "None" },
  { "RAID_WARNING", "Raid warning" },
  { "READY_CHECK", "Ready check" },
  { "ALARM_CLOCK_WARNING_3", "Alarm" },
  { "ALARM_CLOCK_WARNING_2", "Alarm (short)" },
  { "PVP_THROUGH_QUEUE", "Queue pop" },
  { "UI_BNET_TOAST", "Friend toast" },
  { "TELL_MESSAGE", "Whisper" },
}
-- (Boss whisper / boss emote are silent when an addon plays them, and map ping is too quiet: tested in game.)
local FALLBACK = { RAID_WARNING = 8959, READY_CHECK = 8960, ALARM_CLOCK_WARNING_3 = 12889,
  ALARM_CLOCK_WARNING_2 = 12867, PVP_THROUGH_QUEUE = 8459, UI_BNET_TOAST = 18019, TELL_MESSAGE = 3081 }
local VALID = {}
for _, c in ipairs(S.CHOICES) do
  VALID[c[1]] = true
end

-- event -> default sound
S.DEFAULTS = {
  interrupt = "READY_CHECK",
  defensive = "RAID_WARNING",
  bosscall = "none",
  burst = "none",
}
S.EVENTS = { "interrupt", "defensive", "bosscall", "burst" }

local THROTTLE = 2.0
local last = {}

function S.Choice(event)
  local db = ns.db or {}
  local v = db["sound_" .. event]
  if v == nil or not VALID[v] then
    -- unset, or a sound that has since been removed from the list
    return S.DEFAULTS[event]
  end
  return v
end

-- Forget saved choices of sounds that are no longer offered (the dropdown would show them blank).
function S.Migrate()
  local db = ns.db or {}
  for _, event in ipairs(S.EVENTS) do
    local v = db["sound_" .. event]
    if v ~= nil and not VALID[v] then
      db["sound_" .. event] = nil
    end
  end
end

function S.Play(event)
  local db = ns.db or {}
  if db.sounds == false then
    return false
  end
  local name = S.Choice(event)
  if not name or name == "none" then
    return false
  end
  local now = GetTime()
  if last[event] and now - last[event] < THROTTLE then
    return false
  end
  last[event] = now
  local kit = (SOUNDKIT and SOUNDKIT[name]) or FALLBACK[name]
  if kit then
    U.Call(PlaySound, kit, "Master")
    return true
  end
  return false
end
