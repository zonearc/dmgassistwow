/**
 * @module generators/gen-toc
 * @description
 * Generates TOC (Table of Contents) files, Bindings.xml, and BindingNames.lua.
 *
 * Produces:
 * - `DMGAssist.toc` — WoW addon metadata, SavedVariables, load order
 * - `Bindings.xml` — Keybinding definitions (toggle HUD, cycle profiles)
 * - `BindingNames.lua` — Display names for keybindings panel
 *
 * The TOC file controls which Lua files WoW loads and in what order.
 * SavedVariables persist per-character settings across sessions.
 */

import { ADDON_NAME, ADDON_VERSION, WOW_INTERFACE, type AddonData, type AllSpecsData } from "./shared";

export function generateToc(data: AddonData): string {
  return `## Interface: ${WOW_INTERFACE}
## Title: ${ADDON_NAME}
## Notes: DMGAssist — Enhanced rotation HUD for ${data.spec.specName} ${data.spec.className}. Multi-signal highlight ranking powered by SimC data.
## Author: DMGAssist Web Companion
## Version: ${ADDON_VERSION}
## IconTexture: Interface\\Icons\\Spell_Holy_FistOfJustice
## SavedVariables: CLF_Config, CLF_Position, CLF_Profiles, CLF_SlotMap, DMGA_WD_Log, DMGA_WD_Config, DMGA_WD_APIScan
## SavedVariablesPerCharacter: CLF_CharConfig
## OptionalDeps: DBM-Core, BigWigs

BindingNames.lua
Libs/LibStub.lua
Locales.lua
Helpers.lua
Config.lua
Engine.lua
HUD.lua
Settings.lua
Core.lua
Watchdog.lua
`;
}

export function generateBindingNames(): string {
  return `BINDING_HEADER_DMGASSIST = "DMGAssist"
BINDING_NAME_DMGASSIST_CYCLE_MODE = "DMGAssist Cycle Mode (AoE / ST)"
BINDING_NAME_DMGASSIST_TOGGLE_ROLE = "DMGAssist Toggle Role (Tank / DPS)"
`;
}

export function generateBindingsXml(): string {
  return `<Bindings>
  <Binding name="DMGASSIST_CYCLE_MODE" header="DMGASSIST" category="ADDONS">
    if CLF and CLF.CycleMode then CLF.CycleMode() end
  </Binding>
  <Binding name="DMGASSIST_TOGGLE_ROLE" header="DMGASSIST" category="ADDONS">
    if CLF and CLF.ToggleCombatRole then CLF.ToggleCombatRole() end
  </Binding>
</Bindings>
`;
}

export function generateAllSpecsToc(allData: AllSpecsData): string {
  const specCount = allData.specs.length;
  return `## Interface: ${WOW_INTERFACE}
## Title: ${ADDON_NAME}
## Notes: DMGAssist — Enhanced rotation HUD for all ${specCount} specs. Multi-signal highlight ranking powered by SimC data. Auto-detects your class & spec.
## Author: DMGAssist Web Companion
## Version: ${ADDON_VERSION}
## IconTexture: Interface\\Icons\\Spell_Holy_FistOfJustice
## SavedVariables: CLF_Config, CLF_Position, CLF_Profiles, CLF_SlotMap, DMGA_WD_Log, DMGA_WD_Config, DMGA_WD_APIScan
## SavedVariablesPerCharacter: CLF_CharConfig
## OptionalDeps: DBM-Core, BigWigs

BindingNames.lua
Libs/LibStub.lua
Locales.lua
Helpers.lua
Config.lua
Engine.lua
HUD.lua
Settings.lua
Core.lua
Watchdog.lua
`;
}
