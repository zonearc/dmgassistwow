-- Commands.lua: /dmgw and /watchdog

local _, ns = ...
local U = ns.U

local HELP = {
  "/dmgw              open the viewer (summary)",
  "/dmgw probe        run an API probe now (out of combat)",
  "/dmgw export       export everything as one copyable string",
  "/dmgw export last  export only the latest session and probes",
  "/dmgw status       print the summary to chat",
  "/dmgw force on|off force addon restrictions on/off for testing (if the client supports it)",
  "/dmgw clear        wipe all Watchdog data",
  "Easiest export: /reload, then upload WTF/Account/<ACCOUNT>/SavedVariables/DMGAssist_Watchdog.lua",
}

-- Client settings (12.0.5+) that make the game behave as if restrictions were
-- active. Only touched when they exist on this client.
local FORCE_CVARS = {
  "addonCombatRestrictionsForced",
  "addonEncounterRestrictionsForced",
}

local function SetForced(on)
  if InCombatLockdown() then
    U.Print("Change this out of combat.")
    return
  end
  local value = on and "1" or "0"
  local any = false
  for _, name in ipairs(FORCE_CVARS) do
    local ok, current = pcall(C_CVar.GetCVar, name)
    if ok and current ~= nil then
      pcall(C_CVar.SetCVar, name, value)
      any = true
      U.Print("%s = %s", name, value)
    else
      U.Print("%s does not exist on this client.", name)
    end
  end
  ns.Store.Note("force_restrictions", { on = on, applied = any })
  if any and on then
    U.Print("Restrictions forced. Run /dmgw probe now, then /dmgw force off.")
  end
end

SLASH_DMGASSISTWATCHDOG1 = "/dmgw"
SLASH_DMGASSISTWATCHDOG2 = "/watchdog"
SlashCmdList.DMGASSISTWATCHDOG = function(msg)
  local cmd, rest = string.match(string.lower(msg or ""), "^%s*(%S*)%s*(.-)%s*$")
  if not ns.db then
    U.Print("Not ready yet.")
    return
  end
  if cmd == "" or cmd == "show" then
    ns.UI.Toggle()
  elseif cmd == "probe" then
    if InCombatLockdown() then
      U.Print("Out of combat only; an in-combat probe runs automatically in your first fight.")
      return
    end
    local ok, err = pcall(ns.Probe.Run, "manual")
    if ok then
      U.Print("Probe stored.")
      ns.UI.ShowSummary()
    else
      ns.Errors.Record("probe", err)
      U.Print("Probe failed: %s", tostring(U.Safe(err)))
    end
  elseif cmd == "export" then
    ns.UI.ShowExport(rest == "last" and "last" or "all")
  elseif cmd == "status" then
    for line in string.gmatch(ns.Export.Summary(), "[^\n]+") do
      print(line)
    end
  elseif cmd == "force" then
    SetForced(rest == "on")
  elseif cmd == "clear" then
    ns.Store.Clear()
    ns.Errors.OnDatabaseReady()
    U.Print("All Watchdog data cleared.")
  else
    for _, line in ipairs(HELP) do
      print(line)
    end
  end
end

-- Public hook for DMGAssist (or anything else) to drop a line into the
-- current combat session:  DMGAssistWatchdog.Log("rec", spellID)
DMGAssistWatchdog = {
  Log = function(kind, data)
    kind, data = U.Safe(kind, 40), U.Safe(data, 200)
    if ns.Sessions.Active() then
      ns.Sessions.Add("D", kind, data)
    else
      ns.Store.Note("dmgassist", { kind = kind, data = data }) -- outside combat (e.g. end-of-fight summaries)
    end
  end,
  Error = function(message)
    ns.Errors.Record("dmgassist", message)
  end,
  version = ns.VERSION,
}
