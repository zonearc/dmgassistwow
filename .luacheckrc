-- luacheck config for WoW addon code (Lua 5.1 + WoW globals).
std = "lua51"
max_line_length = 140
codes = true
exclude_files = { "legacy/**", ".libraries/**", "addons/DMGAssist/Data/**" }

-- Globals our addons are allowed to create.
globals = {
  "DMGAssistWatchdogDB",
  "DMGAssistWatchdog",
  "DMGAssistDB",
  "SLASH_DMGASSIST1",
  "SLASH_DMGASSIST2",
  "SLASH_DMGASSISTWATCHDOG1",
  "SLASH_DMGASSISTWATCHDOG2",
  "SlashCmdList",
  "UISpecialFrames",
  "BINDING_HEADER_DMGASSIST", "BINDING_NAME_DMGASSIST_CYCLEMODE", "BINDING_NAME_DMGASSIST_BURST",
  "BINDING_NAME_DMGASSIST_TOGGLE", "DMGAssist_CycleMode", "DMGAssist_ToggleBurst", "DMGAssist_Toggle",
  "DMGAssist_OnCompartmentClick",
}

-- WoW API we read. Keep this list to what the code actually uses, so a typo
-- in an API name shows up as an undefined global.
read_globals = {
  "Minimap", "MenuUtil", "GetCursorPosition", "IsShiftKeyDown", "GameTooltip", "BugGrabber",
  "GetShapeshiftFormID",
  "GetPhysicalScreenSize", "GetFramerate", "GetNumGroupMembers", "C_GameRules",
  "UnitHealthPercent",
  "LibStub", "IsMounted", "UnitInVehicle", "C_PetBattles", "PlaySound", "SOUNDKIT", "SettingsPanel",
  "CreateSettingsListSectionHeaderInitializer",
  "C_CurveUtil", "UnitPowerPercent",
  "CreateSettingsButtonInitializer",
  "BuffIconCooldownViewer",
  "C_CooldownViewer", "C_EncounterTimeline", "GetActionInfo", "GetMacroSpell", "DBM", "BigWigsLoader",
  "UnitIsBossMob", "UnitClassification",
  "UnitStagger", "GetSpellBaseCooldown", "IsInRaid", "ShowUIPanel", "GetMaxLevelForPlayerExpansion", "GetMaxPlayerLevel", "C_ClassTalents", "C_Traits",
  "UnitIsUnit", "UnitIsConnected", "UnitIsDeadOrGhost",
  "UnitInRange", "UnitGroupRolesAssigned", "GetWeaponEnchantInfo", "C_Item", "GetItemSpell", "GetItemInfo", "GetInventoryItemID", "GetInventoryItemTexture",
  "GetInventoryItemCooldown", "IsUsableItem", "GetMacroItem",
  "Settings", "MinimalSliderWithSteppersMixin", "STANDARD_TEXT_FONT", "GetBindingKey", "GetBindingText",
  "C_ActionBar", "C_AddOnProfiler", "C_AddOns", "C_AssistedCombat", "C_CVar", "C_ClassTalents", "C_CooldownViewer",
  "C_NamePlate", "C_Traits", "C_UnitAuras", "GetUnitSpeed", "IsStealthed", "UnitAffectingCombat", "UnitCanAttack", "UnitName", "UnitGUID", "UnitIsDead", "IsPlayerSpell", "GetRealmName",
  "UnitExists", "UnitHealthMax", "UnitSpellHaste", "UnitCastingInfo", "UnitChannelInfo",
  "C_DamageMeter", "C_EncodingUtil", "C_GameRules", "C_RestrictedActions", "C_Secrets",
  "C_Spell", "C_SpellActivationOverlay", "C_SpellBook", "C_SpecializationInfo", "C_Timer",
  "WOW_PROJECT_ID", "WOW_PROJECT_MAINLINE", "WOW_PROJECT_CAMELOT",
  "ChatFontNormal", "CreateFrame", "Enum", "GetBuildInfo", "GetCVar", "GetLocale",
  "GetRealZoneText", "GetSpecialization", "GetSpecializationInfo", "GetTime", "InCombatLockdown",
  "IsInInstance", "UIParent", "UnitClass", "UnitHealth", "UnitLevel", "UnitPower", "UnitPowerMax",
  "canaccessvalue", "date", "debugprofilestop", "debugstack", "geterrorhandler", "issecretvalue",
  "seterrorhandler", "tinsert", "wipe",
}

files["tests/**"] = {
  std = "+lua51",
  globals = { "C_EncodingUtil", "DMGAssistWatchdogDB", "DMGAssistWatchdog", "DMGAssistDB", "SlashCmdList",
    "WOW_PROJECT_ID", "DBM", "BigWigsLoader", "BT4Button1", "BT4Button50", "BuffIconCooldownViewer", "SettingsPanel", "GetShapeshiftFormID",
    "ActionButton3", "BugGrabber", "DMGAssistMinimapButton", "DMGAssistWatchdogFrame",
    "MenuUtil", "InCombatLockdown", "UnitAffectingCombat",
    "GetInventoryItemID", "C_Item", "GetInventoryItemCooldown", "UnitHealth", "UnitHealthMax", "UnitStagger", "GetSpellBaseCooldown", "IsPlayerSpell", "IsInInstance", "C_AssistedCombat", "UnitLevel", "GetMaxLevelForPlayerExpansion", "GetCVar", "DMGAssistAPI", "DMGAssistWelcome",
    "C_Spell", "C_UnitAuras", "UnitClass", "GetNumGroupMembers", "UnitGroupRolesAssigned", "UnitExists", "GetWeaponEnchantInfo" },
  read_globals = { "newproxy" },
  allow_defined_top = true,
  ignore = { "212", "213" },
}
