-- Init.lua: event wiring. Loaded last so every module exists.

local ADDON_NAME, ns = ...
local U, S, E, M, P = ns.U, ns.Store, ns.Errors, ns.Sessions, ns.Probe

local frame = CreateFrame("Frame")
ns.eventFrame = frame

local handlers = {}

local function Register(list, handler)
  for _, event in ipairs(list) do
    -- RegisterEvent on an event this client does not know is harmless but
    -- pointless; pcall in case a future client makes it an error.
    pcall(frame.RegisterEvent, frame, event)
    handlers[event] = handler
  end
end

Register({ "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LOGOUT" }, function(event, arg1, arg2)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      S.Init()
      E.OnDatabaseReady()
      S.Note("loaded", { version = ns.VERSION })
    end
    -- Another addon may have replaced the error handler while loading.
    E.Install()
  elseif event == "PLAYER_LOGIN" then
    E.Install()
    if ns.db and ns.db.settings.autoProbe and C_Timer and C_Timer.After then
      C_Timer.After(6, function()
        if InCombatLockdown() then
          return
        end
        local ok, err = pcall(P.Run, "login")
        if not ok then
          E.Record("probe", err)
        end
      end)
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    S.Note("entering_world", { initialLogin = U.Safe(arg1), reload = U.Safe(arg2), zone = U.Safe(GetRealZoneText()) })
  elseif event == "PLAYER_LOGOUT" then
    M.Stop("logout")
  end
end)

Register(E.EVENTS, function(event, ...)
  E.HandleEvent(event, ...)
end)

Register(M.EVENTS, function(event, ...)
  M.HandleEvent(event, ...)
end)

for event, unit in pairs(M.UNIT_EVENTS) do
  pcall(frame.RegisterUnitEvent, frame, event, unit)
  handlers[event] = function(ev, ...)
    M.HandleEvent(ev, ...)
  end
end

frame:SetScript("OnEvent", function(_, event, ...)
  local handler = handlers[event]
  if handler then
    local ok, err = pcall(handler, event, ...)
    if not ok then
      -- Never let our own bug cascade; record it and carry on.
      pcall(E.Record, "watchdog_internal", err, debugstack and debugstack(2) or nil)
    end
  end
end)
