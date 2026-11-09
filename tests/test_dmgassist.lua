-- Run from the repo root:  lua5.1 tests/test_dmgassist.lua
package.path = "./tests/?.lua;" .. package.path

local mock = require("wow_mock")
local print = print -- the mock captures the global print
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

local ADDON = "DMGAssist"

-- Load the addon fresh as a given client.
local function Boot(gameType, project)
  mock.frames = {}
  mock.timers = {}
  mock.printed = {}
  mock.gameType = gameType
  WOW_PROJECT_ID = project
  DMGAssistDB = nil
  local ns = mock.LoadAddon("addons/" .. ADDON, ADDON)
  mock.Fire("ADDON_LOADED", ADDON)
  mock.Fire("PLAYER_LOGIN")
  return ns
end

local function countFiles(prefix)
  local n = 0
  for _, f in ipairs(mock.loadedFiles) do
    if f:sub(1, #prefix) == prefix then
      n = n + 1
    end
  end
  return n
end

print("DMGAssist runtime tests")

test("Midnight client loads only Midnight data and is ready for Retribution", function()
  mock.class, mock.specs, mock.specIndex = { "Paladin", "PALADIN", 2 }, { [1] = 65, [2] = 66, [3] = 70 }, 3
  local ns = Boot("standard", 1)
  eq(countFiles("Data/forever/"), 0, "forever data loaded on Midnight")
  eq(countFiles("Data/midnight/") > 30, true, "midnight data missing")
  local s = ns.Specs.current
  eq(s.branch, "midnight")
  eq(s.key, "paladin_retribution")
  eq(s.status, "ready")
  eq(s.source.branch, "midnight")
  eq(type(s.data.simc.default), "table", "SimC default list missing")
  eq(type(s.data.blizzard.assisted_combat), "table", "Blizzard rules missing")
end)

test("Forever client (Camelot) loads only Forever data", function()
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 102, [2] = 103, [3] = 104, [4] = 105 }, 2
  local ns = Boot("camelot", 18)
  eq(countFiles("Data/midnight/"), 0, "midnight data loaded on Forever")
  eq(countFiles("Data/forever/") > 30, true, "forever data missing")
  local s = ns.Specs.current
  eq(s.client, "WoW Forever")
  eq(s.key, "druid_feral")
  eq(s.status, "ready")
  eq(s.source.branch, "forever")
end)

test("spec change without reload switches data (coalesced into one refresh)", function()
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 102, [2] = 103, [3] = 104, [4] = 105 }, 2
  local ns = Boot("standard", 1)
  local changes = 0
  ns.Specs.OnChange(function()
    changes = changes + 1
  end)
  mock.specIndex = 1
  mock.Fire("PLAYER_SPECIALIZATION_CHANGED", "player")
  mock.Fire("ACTIVE_PLAYER_SPECIALIZATION_CHANGED")
  mock.Fire("TRAIT_CONFIG_UPDATED", 1)
  mock.Fire("SPELLS_CHANGED")
  eq(ns.Specs.current.key, "druid_feral", "should not switch before the coalescing delay")
  mock.Advance(0.3)
  eq(ns.Specs.current.key, "druid_balance")
  eq(changes, 1, "burst of events should produce one change")
  local announced = false
  for _, line in ipairs(mock.printed) do
    if line:find("Spec changed", 1, true) then
      announced = true
    end
  end
  eq(announced, true, "player not told about the spec change")
end)

test("talent edits that keep the same spec do not fire a change", function()
  local ns = Boot("standard", 1)
  local changes = 0
  ns.Specs.OnChange(function()
    changes = changes + 1
  end)
  mock.Fire("TRAIT_CONFIG_UPDATED", 1)
  mock.Advance(0.3)
  eq(changes, 0)
end)

test("healer spec without a SimC list runs DMGAssist's own list and says so", function()
  mock.class, mock.specs, mock.specIndex = { "Paladin", "PALADIN", 2 }, { [1] = 65, [2] = 66, [3] = 70 }, 1
  local ns = Boot("standard", 1)
  eq(ns.Specs.current.key, "paladin_holy")
  eq(ns.Specs.current.status, "ready", "the HUD works")
  eq(ns.Specs.current.data.community, true, "DMGAssist's own list")
  eq(ns.Describe(ns.Specs.current):find("own list", 1, true) ~= nil, true)
  eq(ns.Display.ModeText():find("Healer", 1, true), nil, "no special title: the Help page explains it")
end)

test("low-level character with no spec follows Blizzard's assistant", function()
  mock.specIndex = nil
  local ns = Boot("camelot", 18)
  eq(ns.Specs.current.status, "ready")
  eq(ns.Specs.current.starter, true, "starter: Blizzard's assistant leads")
  eq(ns.Describe(ns.Specs.current):find("starter spec", 1, true) ~= nil, true)
  mock.specIndex = 2
end)

test("a starter spec ID (no SimC list) follows Blizzard's assistant, not crashed on", function()
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 1447 }, 1
  local ns = Boot("standard", 1)
  eq(ns.Specs.current.status, "ready")
  eq(ns.Specs.current.key, "druid_starter")
  local saved = C_AssistedCombat
  C_AssistedCombat = nil
  ns = Boot("standard", 1)
  eq(ns.Specs.current.status, "unknown_spec", "without the assistant it is still reported")
  C_AssistedCombat = saved
end)

test("unsupported client is reported", function()
  mock.specs, mock.specIndex = { [1] = 103 }, 1
  local ns = Boot("standard", 2)
  eq(ns.Specs.current.status, "unsupported_client")
end)

test("spec changes are logged to the Watchdog when it is installed", function()
  local logged = {}
  DMGAssistWatchdog = {
    Log = function(kind, data)
      logged[#logged + 1] = kind .. "=" .. tostring(data)
    end,
  }
  mock.class, mock.specs, mock.specIndex = { "Druid", "DRUID", 11 }, { [1] = 102, [2] = 103 }, 2
  Boot("standard", 1)
  DMGAssistWatchdog = nil
  eq(logged[1], "spec=druid_feral:ready")
end)

test("/dmga reports status", function()
  Boot("standard", 1)
  SlashCmdList.DMGASSIST("")
  local found = false
  for _, line in ipairs(mock.printed) do
    if line:find("druid_feral", 1, true) then
      found = true
    end
  end
  eq(found, true)
end)

test("every SimC spec in the data maps from a Blizzard spec ID", function()
  local ns = Boot("standard", 1)
  local known = {}
  for _, key in pairs(ns.Specs.KEYS) do
    known[key] = true
  end
  for key in pairs(ns.Data.specs.midnight) do
    eq(known[key], true, "no spec ID maps to " .. key)
  end
end)

test("minimap button: left-click shows/hides, drag moves, right-click menu has settings and toggles", function()
  local ns = Boot("standard")
  local b = DMGAssistMinimapButton
  eq(type(b), "table", "button created")
  eq(b:IsShown(), true)
  -- left-click: show / hide
  local before = ns.db.enabled ~= false
  b.scripts.OnClick(b, "LeftButton")
  eq(ns.db.enabled ~= false, not before, "left-click toggles")
  b.scripts.OnClick(b, "LeftButton")
  -- drag: moves, and the mouse-up that ends the drag is not a click
  b.scripts.OnDragStart(b)
  b.scripts.OnUpdate(b)
  b.scripts.OnDragStop(b)
  eq(ns.db.minimapAngle, 0, "dragging saves the angle")
  before = ns.db.enabled ~= false
  b.scripts.OnClick(b, "LeftButton")
  eq(ns.db.enabled ~= false, before, "end of drag does not toggle")
  -- right-click: the menu
  local items = {}
  local root = {
    CreateTitle = function(_, t) items[#items + 1] = { kind = "title", text = t } end,
    CreateButton = function(_, t, fn) items[#items + 1] = { kind = "button", text = t, fn = fn } end,
    CreateDivider = function() end,
    CreateCheckbox = function(_, t, get, set) items[#items + 1] = { kind = "check", text = t, get = get, set = set } end,
    CreateRadio = function(_, t, get, set) items[#items + 1] = { kind = "radio", text = t, get = get, set = set } end,
  }
  DMGAssistWatchdog = { OpenReport = function() end }
  MenuUtil = { CreateContextMenu = function(owner, gen) eq(owner, b) gen(owner, root) end }
  b.scripts.OnClick(b, "RightButton")
  MenuUtil, DMGAssistWatchdog = nil, nil
  local by = {}
  for _, it in ipairs(items) do
    by[it.text] = it
  end
  for _, name in ipairs({ "Settings", "Report an issue", "Hide minimap button" }) do
    eq(by[name] and by[name].kind, "button", name)
  end
  for _, name in ipairs({ "Show recommendations", "Show out of combat", "Major cooldowns", "Lock position",
    "Sound alerts" }) do
    local it = by[name]
    eq(it and it.kind, "check", name)
    local was = it.get()
    it.set()
    eq(it.get(), not was, name .. " flips")
    it.set()
  end
  by["Single target"].set()
  eq(by["Single target"].get(), true)
  eq(by["Auto-detect"].get(), false)
  by["Auto-detect"].set()
  eq(by["Auto-detect"].get(), true)
  local opened = 0
  local open = ns.Options.Open
  ns.Options.Open = function() opened = opened + 1 end
  by["Settings"].fn()
  ns.Options.Open = open
  eq(opened, 1, "menu opens settings")
  DMGAssist_OnCompartmentClick("DMGAssist", "LeftButton")
  by["Hide minimap button"].fn()
  eq(b:IsShown(), false, "hidden from the menu")
end)

test("sounds: removed choices fall back to the default; keybind color applies", function()
  DMGAssistDB = { sound_interrupt = "UI_RAID_BOSS_WHISPER_WARNING", sound_defensive = "RAID_WARNING" }
  local ns = Boot("standard")
  eq(ns.db.sound_interrupt, nil, "silent sound forgotten")
  eq(ns.Sounds.Choice("interrupt"), "READY_CHECK")
  eq(ns.Sounds.Choice("defensive"), "RAID_WARNING")
  for _, c in ipairs(ns.Sounds.CHOICES) do
    eq(c[1] == "none" or SOUNDKIT[c[1]] ~= nil, true, c[1] .. " is in the mock's SOUNDKIT")
  end
  ns.db.hud = ns.db.hud or {}
  ns.db.hud.keybindColor = "cyan"
  local colors = {}
  for _, c in ipairs(ns.Display.TEXT_COLORS) do
    colors[c[1]] = true
  end
  eq(colors.cyan, true)
end)

test("settings asked for in combat open when the fight ends (the game blocks them in combat)", function()
  local ns = Boot("standard")
  local opened = 0
  _G.Settings.OpenToCategory = function() opened = opened + 1 end
  mock.inCombat = true
  eq(ns.Options.Open(), false)
  eq(opened, 0, "not in combat")
  mock.inCombat = false
  mock.Fire("PLAYER_REGEN_ENABLED")
  eq(opened, 1, "opened after combat")
  mock.Fire("PLAYER_REGEN_ENABLED")
  eq(opened, 1, "only once")
end)

test("Status page: live summary, help links, and a reset of everything", function()
  local ns = Boot("standard")
  local f = ns.Options.statusFrame
  eq(type(f), "table", "status page registered")
  f.scripts.OnShow(f)
  local text = ns.Options.statusBody.text
  eq(type(text), "string", "summary shown")
  for _, needle in ipairs({ "Version:", "Game:", "Target mode:", "Boss mods found:", "Keybinds read" }) do
    eq(text:find(needle, 1, true) ~= nil, true, needle)
  end
  local links = 0
  for _, child in ipairs(mock.frames) do
    if type(child.text) == "string" and (child.text:find("github.com/zonearc/dmgassist-issues", 1, true)
      or child.text:find("curseforge.com/wow/addons/dmgassist", 1, true)) then
      links = links + 1
    end
  end
  eq(links >= 2, true, "copyable links: CurseForge and the report page")
  ns.db.mode = "st"
  ns.Options.ResetAll()
  eq(ns.db.mode, "aoe", "reset everything: AoE is the default target mode")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
if failed > 0 then
  os.exit(1)
end
