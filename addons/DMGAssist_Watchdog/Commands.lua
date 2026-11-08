-- Commands.lua: /dmgw and /watchdog

local _, ns = ...
local U = ns.U

local HELP = {
  "/dmgw              open the report, selected: Ctrl+C, then paste it into the chat",
  "/dmgw probe        run an API probe now (out of combat)",
  "/dmgw export       export everything as one copyable string",
  "/dmgw export last  export only the latest session and probes",
  "/dmgw status       print the summary to chat",
  "/dmgw force on|off force addon restrictions on/off for testing (if the client supports it)",
  "/dmgw taint on|off write the game's taint log (Logs/taint.log) for blocked/forbidden actions",
  "/dmgw testing on|off test-build logging (taint log, more events, notices); on by default while we test",
  "/dmgw launch      record the launch snapshot again (addons, CVars, client, restrictions)",
  "/dmgw clear        wipe all Watchdog data",
  "No /reload needed: the report always holds what happened up to now.",
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
  elseif cmd == "testing" then
    ns.Launch.SetTesting(rest ~= "off")
  elseif cmd == "launch" then
    ns.Launch.Snapshot("manual")
    U.Print("Launch snapshot stored.")
  elseif cmd == "taint" then
    -- taintLog 1 = blocked actions with the addon that caused them; 2 = also every taint step (verbose).
    if InCombatLockdown() then
      U.Print("Change this out of combat.")
      return
    end
    local value = rest == "off" and "0" or (rest == "full" and "2" or "1")
    pcall(C_CVar.SetCVar, "taintLog", value)
    ns.Store.Note("taint_log", { value = value })
    U.Print("taintLog = %s. After playing, /reload or log out; the file is World of Warcraft/_retail_/Logs/taint.log.",
      value)
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
    -- end-of-fight summaries are long single lines; everything else stays short
    local limit = (type(kind) == "string" and kind:find("_summary$")) and 2000 or 200
    kind, data = U.Safe(kind, 40), U.Safe(data, limit)
    if ns.Sessions.Active() then
      ns.Sessions.Add("D", kind, data)
    else
      ns.Store.Note("dmgassist", { kind = kind, data = data }) -- outside combat (e.g. end-of-fight summaries)
    end
  end,
  Error = function(message)
    ns.Errors.Record("dmgassist", message)
  end,
  -- Open the panel with the report selected (DMGAssist's minimap button, shift-click).
  OpenReport = function()
    ns.UI.ShowExport("last")
  end,
  version = ns.VERSION,
}
