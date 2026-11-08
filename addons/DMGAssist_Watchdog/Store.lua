-- Store.lua: owns DMGAssistWatchdogDB (SavedVariables). Every list is capped
-- so the file can never grow past what WoW is willing to save.

local _, ns = ...
local U = ns.U

local S = {}
ns.Store = S

ns.SCHEMA = 1

local DEFAULT_SETTINGS = {
  captureErrors = true,   -- chain onto the global Lua error handler
  logCasts = true,        -- record the player's own casts in combat sessions
  logGlows = true,        -- record proc glows (spell activation overlays)
  autoProbe = true,       -- probe once after login, once in the first real combat
  testingMode = false,    -- test builds: taint log on, more events kept, login notice (see Launch.lua)
  maxSessions = 8,
  maxEventsPerSession = 600,
  maxErrors = 60,
  maxNotes = 200,
  maxProbes = 6,
}

local function Fill(target, defaults)
  for k, v in pairs(defaults) do
    if target[k] == nil then
      target[k] = v
    end
  end
end

function S.Init()
  local db = DMGAssistWatchdogDB
  if type(db) ~= "table" or db.schema ~= ns.SCHEMA then
    db = { schema = ns.SCHEMA }
  end
  db.settings = type(db.settings) == "table" and db.settings or {}
  Fill(db.settings, DEFAULT_SETTINGS)
  db.errors = db.errors or {}     -- deduplicated Lua errors and blocked actions
  db.sessions = db.sessions or {} -- combat sessions (ring)
  db.probes = db.probes or {}     -- API probe results (ring)
  db.notes = db.notes or {}       -- everything outside combat (ring)
  db.counters = db.counters or {}
  db.loginCount = (db.loginCount or 0) + 1
  DMGAssistWatchdogDB = db
  ns.db = db
  return db
end

function S.Push(list, item, max)
  list[#list + 1] = item
  while #list > max do
    table.remove(list, 1)
  end
end

function S.Count(key, amount)
  local db = ns.db
  if not db then
    return
  end
  db.counters[key] = (db.counters[key] or 0) + (amount or 1)
end

-- A timestamped line outside any combat session.
function S.Note(kind, data)
  local db = ns.db
  if not db then
    return
  end
  S.Push(db.notes, { t = U.Round2(U.Now()), when = date("%H:%M:%S"), kind = kind, data = data }, db.settings.maxNotes)
end

function S.Clear()
  local settings = ns.db and ns.db.settings
  DMGAssistWatchdogDB = { schema = ns.SCHEMA, settings = settings }
  S.Init()
end
