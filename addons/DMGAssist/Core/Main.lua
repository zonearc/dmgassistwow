-- Main.lua: startup, events, slash commands. Loaded after the generated data.

local ADDON_NAME, ns = ...
local U, Specs = ns.U, ns.Specs

local STATUS_TEXT = {
  ready = "ready",
  no_spec = "no specialization chosen yet",
  unknown_spec = "unknown specialization",
  no_simc_list = "SimC has no priority list for this spec (healer support comes later)",
  data_not_loaded = "priority data for this client did not load",
  unsupported_client = "this game client is not supported",
}

local function Describe(state)
  if not state then
    return "not started"
  end
  local parts = {
    string.format("%s, %s %s", tostring(state.client), tostring(state.class), tostring(state.key or state.specName or "-")),
    STATUS_TEXT[state.status] or tostring(state.status),
  }
  if state.source then
    parts[#parts + 1] = string.format("SimC %s %s (%s)", tostring(state.source.branch), tostring(state.source.commit),
      tostring(state.source.date))
  end
  return table.concat(parts, " | ")
end
ns.Describe = Describe

Specs.OnChange(function(state, previous)
  if previous then
    U.Print("Spec changed: %s", Describe(state))
  end
end)

local frame = CreateFrame("Frame")
ns.eventFrame = frame
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
for _, event in ipairs(Specs.EVENTS) do
  if event == "PLAYER_SPECIALIZATION_CHANGED" then
    pcall(frame.RegisterUnitEvent, frame, event, "player")
  else
    pcall(frame.RegisterEvent, frame, event)
  end
end

frame:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      DMGAssistDB = type(DMGAssistDB) == "table" and DMGAssistDB or {}
      ns.db = DMGAssistDB
      ns.Client.Detect()
    end
  elseif event == "PLAYER_LOGIN" then
    local state = Specs.Refresh("login")
    U.Print("%s", Describe(state))
    local loaded = ns.Data.LoadedBranches()
    if #loaded > 1 then
      U.Print("Warning: data for %s loaded at once; using %s.", table.concat(loaded, " and "), tostring(state.branch))
      U.Log("data_gating", table.concat(loaded, ","))
    end
  else
    Specs.RequestRefresh(event)
  end
end)

SLASH_DMGASSIST1 = "/dmga"
SLASH_DMGASSIST2 = "/dmgassist"
SlashCmdList.DMGASSIST = function()
  local state = Specs.Refresh("slash")
  U.Print("%s", Describe(state))
  U.Print("Recommendations are not switched on yet in this build; this version checks client, spec and data.")
end
