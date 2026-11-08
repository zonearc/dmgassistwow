-- Client.lua: which game are we running in?
--
-- Verified in Blizzard's UI source (Blizzard_ProjectConstants): WOW_PROJECT_MAINLINE = 1 (Midnight),
-- WOW_PROJECT_CAMELOT = 18 (WoW Forever). The data branch names match tools/simc_import.py.

local _, ns = ...
local U = ns.U

local C = {}
ns.Client = C

local MAINLINE, CAMELOT = 1, 18

function C.Detect()
  local project = U.Safe(WOW_PROJECT_ID)
  local mainline = U.Safe(WOW_PROJECT_MAINLINE) or MAINLINE
  local camelot = U.Safe(WOW_PROJECT_CAMELOT) or CAMELOT
  local info = { project = project }
  if project == camelot then
    info.branch, info.name = "forever", "WoW Forever"
  elseif project == mainline then
    info.branch, info.name = "midnight", "Midnight"
  else
    info.branch, info.name = nil, "unsupported client"
  end
  local b = U.Try(GetBuildInfo)
  if b.ok then
    info.version, info.build, info.interface = b[1], b[2], b[4]
  end
  C.info = info
  return info
end
