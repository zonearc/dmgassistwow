-- Run from the repo root:  lua5.1 tests/test_watchdog.lua
package.path = "./tests/?.lua;" .. package.path

local mock = require("wow_mock")
local print = print -- keep the real print; the mock captures the global one
mock.Install(_G)

local passed, failed = 0, 0
local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
    print("  ok   " .. name)
  else
    failed = failed + 1
    print("  FAIL " .. name .. "\n       " .. tostring(err))
  end
end
local function eq(a, b, msg)
  if a ~= b then
    error((msg or "values differ") .. ": expected " .. tostring(b) .. ", got " .. tostring(a), 2)
  end
end
local function truthy(v, msg)
  if not v then
    error(msg or "expected truthy value", 2)
  end
end

-- An error raised by "another addon" before our SavedVariables load.
local ADDON = "DMGAssist_Watchdog"
local ns = mock.LoadAddon("addons/" .. ADDON, ADDON)

print("DMGAssist_Watchdog tests")

test("error handler installed at file load and buffers before ADDON_LOADED", function()
  truthy(ns.Errors.IsInstalled(), "handler not installed")
  geterrorhandler()("Interface/AddOns/Other/x.lua:1: early boom")
  eq(mock.lastDefaultError, "Interface/AddOns/Other/x.lua:1: early boom", "previous handler not chained")
end)

test("ADDON_LOADED creates the database and flushes buffered errors", function()
  mock.Fire("ADDON_LOADED", ADDON)
  truthy(DMGAssistWatchdogDB, "no SavedVariables table")
  eq(DMGAssistWatchdogDB.schema, 1)
  eq(#DMGAssistWatchdogDB.errors, 1, "buffered error not flushed")
  eq(DMGAssistWatchdogDB.errors[1].kind, "lua")
end)

test("repeated errors are deduplicated with a count", function()
  geterrorhandler()("same error")
  geterrorhandler()("same error")
  local last = DMGAssistWatchdogDB.errors[#DMGAssistWatchdogDB.errors]
  eq(last.msg, "same error")
  eq(last.count, 2)
end)

test("a secret error message is stored as a marker, not passed around", function()
  geterrorhandler()(mock.Secret())
  local last = DMGAssistWatchdogDB.errors[#DMGAssistWatchdogDB.errors]
  eq(last.msg, "<secret>")
end)

test("re-chains if someone else replaces the error handler", function()
  local theirs = function() end
  seterrorhandler(theirs)
  truthy(not ns.Errors.IsInstalled())
  mock.Fire("ADDON_LOADED", "SomeOtherAddon")
  truthy(ns.Errors.IsInstalled(), "did not re-install")
end)

test("ADDON_ACTION_FORBIDDEN is recorded", function()
  mock.Fire("ADDON_ACTION_FORBIDDEN", "DMGAssist", "RegisterEvent()")
  local last = DMGAssistWatchdogDB.errors[#DMGAssistWatchdogDB.errors]
  eq(last.kind, "forbidden")
  truthy(last.msg:find("RegisterEvent", 1, true), "function name missing")
end)

test("login probe runs out of combat and records Forever feature flags", function()
  mock.Fire("PLAYER_LOGIN")
  mock.Advance(7)
  local p = ns.Probe.Latest("login")
  truthy(p, "no login probe")
  eq(p.env.interface, 16001)
  eq(p.features.assistedCombatAvailable, false)
  eq(p.features.assistedCombatFailureReason, "Not available in this game mode")
  eq(p.features.cooldownViewerAvailable, true)
  eq(#p.spells, 2, "passive spell should be skipped")
  eq(p.spells[1].name, "Crusader Strike")
  eq(p.spells[1].barSlots, 1)
  eq(p.restrictions.cvars.addonCombatRestrictionsForced, "0")
end)

test("combat session records casts, secret spellIDs and glows", function()
  mock.restricted = true
  mock.inCombat = true
  mock.Fire("PLAYER_REGEN_DISABLED")
  truthy(ns.Sessions.Active())
  mock.Advance(1)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-guid", 35395)
  mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", mock.Secret(), mock.Secret())
  mock.Fire("SPELL_ACTIVATION_OVERLAY_GLOW_SHOW", 20271)
  mock.Fire("ADDON_RESTRICTION_STATE_CHANGED", 0, 2)
  local s = ns.Sessions.Current()
  eq(s.events[1][2], "C")
  eq(s.events[1][3], 35395)
  eq(s.events[2][3], "<secret>")
  eq(s.events[3][2], "G+")
  eq(s.events[4][2], "R")
end)

test("in-combat probe runs once, survives secrets, and marks them", function()
  mock.Advance(3.5)
  local p = ns.Probe.Latest("combat")
  truthy(p, "no combat probe")
  eq(p.restrictions.states.Combat, 2)
  eq(p.secretSelfTest.healthPlayer.isSecret, true)
  eq(p.secretSelfTest.healthPlayer.value, "<secret>")
  eq(p.spells[1].cdSecret, true)
  eq(p.spells[1].cdActive, false, "isActive is never secret")
  eq(p.spells[1].cdDuration, "<secret>")
  eq(p.powers.HolyPower.value, 3, "holy power stays readable")
  eq(p.powers.Mana.value, "<secret>")
  local count = 0
  for _, probe in ipairs(DMGAssistWatchdogDB.probes) do
    if probe.label == "combat" then
      count = count + 1
    end
  end
  eq(count, 1)
end)

test("session closes with duration and perf data", function()
  mock.Advance(10)
  mock.Fire("PLAYER_REGEN_ENABLED")
  mock.restricted = false
  mock.inCombat = false
  truthy(not ns.Sessions.Active())
  local s = DMGAssistWatchdogDB.sessions[#DMGAssistWatchdogDB.sessions]
  eq(s.duration, 14.5)
  truthy(s.perf and s.perf.DMGAssist_Watchdog, "perf missing")
end)

test("events per session are capped and drops are counted", function()
  DMGAssistWatchdogDB.settings.maxEventsPerSession = 5
  mock.Fire("PLAYER_REGEN_DISABLED")
  for i = 1, 9 do
    mock.Fire("UNIT_SPELLCAST_SUCCEEDED", "player", "g" .. i, 100 + i)
  end
  local s = ns.Sessions.Current()
  eq(#s.events, 5)
  eq(s.dropped, 4)
  mock.Fire("PLAYER_REGEN_ENABLED")
  DMGAssistWatchdogDB.settings.maxEventsPerSession = 600
end)

test("fallback export round-trips as a Lua table", function()
  local str, fmt = ns.Export.Encode()
  eq(fmt, "lua")
  eq(str:sub(1, 6), "DMGW0:")
  local data = assert(loadstring("return " .. str:sub(7)))()
  eq(data.format, "dmgassist-watchdog")
  truthy(#data.probes >= 2)
  truthy(#data.sessions >= 1)
end)

test("encoded export is used when C_EncodingUtil exists", function()
  C_EncodingUtil = {
    SerializeJSON = function()
      return "{}"
    end,
    CompressString = function(s)
      return "z" .. s
    end,
    EncodeBase64 = function(s)
      return "b64(" .. s .. ")"
    end,
  }
  local str, fmt = ns.Export.Encode()
  eq(fmt, "json+deflate+base64")
  eq(str, "DMGW1:b64(z{})")
  C_EncodingUtil = nil
end)

test("summary and slash commands do not error", function()
  truthy(ns.Export.Summary():find("Assisted Combat available: false", 1, true), "summary missing AC line")
  SlashCmdList.DMGASSISTWATCHDOG("help")
  SlashCmdList.DMGASSISTWATCHDOG("status")
  SlashCmdList.DMGASSISTWATCHDOG("")
  SlashCmdList.DMGASSISTWATCHDOG("export last")
end)

test("force restrictions only touches CVars that exist", function()
  mock.cvarsMissing.addonEncounterRestrictionsForced = true
  SlashCmdList.DMGASSISTWATCHDOG("force on")
  eq(mock.cvars.addonCombatRestrictionsForced, "1")
  eq(mock.cvars.addonEncounterRestrictionsForced, nil)
  SlashCmdList.DMGASSISTWATCHDOG("force off")
  eq(mock.cvars.addonCombatRestrictionsForced, "0")
end)

test("public hook logs into the current session", function()
  mock.Fire("PLAYER_REGEN_DISABLED")
  DMGAssistWatchdog.Log("rec", 35395)
  local s = ns.Sessions.Current()
  eq(s.events[#s.events][2], "D")
  eq(s.events[#s.events][4], 35395)
  mock.Fire("PLAYER_REGEN_ENABLED")
end)

test("BugSack users: errors BugGrabber caught are pulled into the report", function()
  local bugs = {
    { message = "MainMenuBarMicroButtons.lua:425: attempt to call a nil value", stack = "[C]: ?", counter = 225,
      session = 7, locals = "self=PlayerSpellsMicroButton" },
    { message = "old session error", counter = 1, session = 6 },
  }
  BugGrabber = {
    GetDB = function() return bugs end,
    GetSessionId = function() return 7 end,
  }
  eq(ns.Errors.PullBugGrabber(), 1, "only this session's error")
  local found
  for _, e in ipairs(DMGAssistWatchdogDB.errors) do
    if e.msg:find("MicroButtons", 1, true) then
      found = e
    end
  end
  eq(found and found.count, 225, "BugGrabber's count kept")
  eq(found.source, "BugGrabber")
  eq(ns.Errors.PullBugGrabber(), 0, "pulling again adds nothing")
  bugs[1].counter = 230
  ns.Errors.PullBugGrabber()
  eq(found.count, 230, "count follows BugGrabber")
  eq(ns.Export.Summary():find("via BugGrabber", 1, true) ~= nil, true, "summary shows it")
  BugGrabber = { GetDB = function() error("changed API") end }
  eq(ns.Errors.PullBugGrabber(), 0, "a broken BugGrabber is harmless")
  BugGrabber = nil
end)

test("/dmgw opens the report already selected, and DMGAssist can open it too", function()
  ns.UI.ShowSummary() -- make sure the panel exists, then start closed
  local frame = DMGAssistWatchdogFrame
  frame:Hide()
  ns.UI.Toggle()
  eq(frame:IsShown(), true)
  frame:Hide()
  DMGAssistWatchdog.OpenReport()
  eq(frame:IsShown(), true)
  frame:Hide()
end)

test("one report: fits the size limit, keeps the newest fights, never leaves old text behind", function()
  for i = 1, 12 do
    mock.Fire("PLAYER_REGEN_DISABLED")
    for j = 1, 300 do
      DMGAssistWatchdog.Log("pick", "main=moonfire next=sunfire fight=" .. i .. " n=" .. j)
    end
    mock.Fire("PLAYER_REGEN_ENABLED")
  end
  local limit = ns.Export.REPORT_LIMIT
  ns.Export.REPORT_LIMIT = 20000
  local str = ns.Export.Encode()
  truthy(#str <= 20000, "report trimmed to the limit: " .. #str)
  local data = assert(loadstring("return " .. str:sub(7)))()
  truthy(data.trimmed, "marked as trimmed")
  local last = data.sessions[#data.sessions]
  eq(last.id, DMGAssistWatchdogDB.sessions[#DMGAssistWatchdogDB.sessions].id, "newest fight kept")
  ns.Export.REPORT_LIMIT = limit
  -- the panel: one button; a box that keeps only part of the text makes the report smaller, never half-copied
  ns.UI.ShowSummary()
  local box
  for _, f in ipairs(mock.frames) do
    if f.type == "EditBox" then
      box = f
    end
  end
  local realSet = box.SetText
  box.SetText = function(self, t)
    realSet(self, string.sub(t, 1, 16000)) -- a box that holds less than the full report
  end
  box.GetText = function(self)
    return self.text
  end
  eq(ns.UI.ShowReport(), true, "fits after shrinking")
  truthy(#box.text <= 16000)
  eq(box.text:sub(1, 5), "DMGW0", "the box holds a whole report, not the summary")
  -- a box that can't hold even the smallest report: a clear message, no partial string
  box.SetText = function(self, t)
    realSet(self, string.sub(t, 1, 500))
  end
  eq(ns.UI.ShowReport(), false)
  eq(box.text:sub(1, 4) ~= "DMGW", true, "no half report left to copy")
  box.SetText = realSet
  ns.Export.REPORT_LIMIT = limit
end)

test("no internal watchdog errors were recorded", function()
  for _, e in ipairs(DMGAssistWatchdogDB.errors) do
    if e.kind == "watchdog_internal" or e.kind == "probe" then
      error("internal error: " .. tostring(e.msg))
    end
  end
end)

test("clear wipes data but keeps settings", function()
  DMGAssistWatchdogDB.settings.logGlows = false
  SlashCmdList.DMGASSISTWATCHDOG("clear")
  eq(#DMGAssistWatchdogDB.errors, 0)
  eq(DMGAssistWatchdogDB.settings.logGlows, false)
end)

test("launch snapshot: client, addons with versions, CVars, restrictions, load order", function()
  mock.cvars.taintLog = "0"
  mock.Fire("ADDON_LOADED", "BigWigs")
  mock.Fire("PLAYER_LOGIN")
  mock.Advance(5)
  local snap = ns.db.launch[#ns.db.launch]
  truthy(snap, "snapshot stored")
  eq(snap.client.locale, "enUS")
  eq(snap.client.screen, "2560x1440")
  eq(#snap.addons, 4)
  eq(snap.addons[3].name, "BigWigs")
  eq(snap.addons[3].version, "v400")
  eq(snap.addons[4].loaded, false)
  eq(snap.cvars.taintLog, "0", "value at login, before testing mode applied")
  truthy(snap.secrets.restriction_Combat ~= nil, "restriction state recorded")
  local sawBigWigs = false
  for _, e in ipairs(snap.addonLoadOrder) do
    if e[1] == "BigWigs" then
      sawBigWigs = true
    end
  end
  truthy(sawBigWigs, "load order recorded")
end)

test("testing mode: off in release builds; switched on, the taint log is on; off restores it", function()
  eq(ns.db.settings.testingMode, false, "off by default in release builds")
  eq(mock.cvars.taintLog, "0", "taint log left alone")
  SlashCmdList.DMGASSISTWATCHDOG("testing on")
  eq(mock.cvars.taintLog, "1", "turned on")
  SlashCmdList.DMGASSISTWATCHDOG("testing off")
  eq(mock.cvars.taintLog, "0", "restored")
  eq(ns.db.settings.maxEventsPerSession, 600)
  SlashCmdList.DMGASSISTWATCHDOG("testing on")
  eq(mock.cvars.taintLog, "1")
  eq(ns.db.settings.maxEventsPerSession, 1500)
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
