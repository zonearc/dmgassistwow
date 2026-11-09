package.path = "./tests/?.lua;" .. package.path
local mock = require("wow_mock")
local out = io.open(arg[1], "w")
mock.Install(_G)
local seen = {}
mock.frames, mock.timers, mock.printed = {}, {}, {}
mock.gameType = "standard"
WOW_PROJECT_ID = 1
DMGAssistDB = nil
local ns = mock.LoadAddon("addons/DMGAssist", "DMGAssist")
local mt = getmetatable(ns.L)
local old = mt.__index
mt.__index = function(t, k)
  if type(k) == "string" and not seen[k] then
    seen[k] = true
  end
  return old(t, k)
end
mock.Fire("ADDON_LOADED", "DMGAssist")
mock.Fire("PLAYER_LOGIN")
pcall(ns.Options.Register)
for _, f in ipairs(mock.frames) do
  local s = f.scripts and f.scripts.OnShow
  if s then pcall(s, f) end
end
pcall(ns.Welcome.Open)
local W = DMGAssistWelcome
if W then
  for i = 1, 3 do pcall(W.buttons[1].scripts.OnClick, W.buttons[1]) end
end
for k in pairs(seen) do
  out:write(k:gsub("\n", "\\n"), "\n")
end
out:close()
