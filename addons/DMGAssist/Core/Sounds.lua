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
  { "UI_RAID_BOSS_WHISPER_WARNING", "Boss whisper" },
  { "RAID_BOSS_EMOTE_WARNING", "Boss emote" },
  { "ALARM_CLOCK_WARNING_3", "Alarm" },
  { "READY_CHECK", "Ready check" },
  { "MAP_PING", "Map ping" },
  { "TELL_MESSAGE", "Whisper" },
}
local FALLBACK = { RAID_WARNING = 8959, UI_RAID_BOSS_WHISPER_WARNING = 37666, RAID_BOSS_EMOTE_WARNING = 12197,
  ALARM_CLOCK_WARNING_3 = 12889, READY_CHECK = 8960, MAP_PING = 3175, TELL_MESSAGE = 3081 }

-- event -> default sound
S.DEFAULTS = {
  interrupt = "UI_RAID_BOSS_WHISPER_WARNING",
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
  if v == nil then
    return S.DEFAULTS[event]
  end
  return v
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
