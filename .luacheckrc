-- luacheck config for WoW addon code (Lua 5.1 + WoW globals).
std = "lua51"
max_line_length = 140
codes = true
exclude_files = { "legacy/**", ".libraries/**" }

-- Globals our addons are allowed to create.
globals = {
  "DMGAssistWatchdogDB",
  "DMGAssistWatchdog",
  "SLASH_DMGASSISTWATCHDOG1",
  "SLASH_DMGASSISTWATCHDOG2",
  "SlashCmdList",
  "UISpecialFrames",
}

-- WoW API we read. Keep this list to what the code actually uses, so a typo
-- in an API name shows up as an undefined global.
read_globals = {
  "C_ActionBar", "C_AddOnProfiler", "C_AddOns", "C_AssistedCombat", "C_CVar", "C_CooldownViewer",
  "C_DamageMeter", "C_EncodingUtil", "C_GameRules", "C_RestrictedActions", "C_Secrets",
  "C_Spell", "C_SpellActivationOverlay", "C_SpellBook", "C_SpecializationInfo", "C_Timer",
  "ChatFontNormal", "CreateFrame", "Enum", "GetBuildInfo", "GetCVar", "GetLocale",
  "GetRealZoneText", "GetSpecialization", "GetSpecializationInfo", "GetTime", "InCombatLockdown",
  "IsInInstance", "UIParent", "UnitClass", "UnitHealth", "UnitLevel", "UnitPower", "UnitPowerMax",
  "canaccessvalue", "date", "debugprofilestop", "debugstack", "geterrorhandler", "issecretvalue",
  "seterrorhandler", "tinsert", "wipe",
}

files["tests/**"] = {
  std = "+lua51",
  globals = { "C_EncodingUtil", "DMGAssistWatchdogDB", "DMGAssistWatchdog", "SlashCmdList" },
  read_globals = { "newproxy" },
  ignore = { "212", "213" },
}
