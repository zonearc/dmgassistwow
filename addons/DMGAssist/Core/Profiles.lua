-- Profiles.lua: settings profiles, shared across characters or per character (the usual addon pattern).
--
-- DMGAssistDB (account-wide saved variables):
--   profiles = { Default = { ...settings... }, ["Name - Realm"] = { ... }, ... }
--   chars    = { ["Name - Realm"] = "profile name" }   (a character without an entry uses "Default")
--   fights, learned                                     (learned data: shared by every profile)
-- ns.db is the active profile's settings table; ns.global is DMGAssistDB itself.
-- Settings saved before profiles existed become the "Default" profile, so nobody loses their setup.

local _, ns = ...
local U = ns.U

local P = {}
ns.Profiles = P

P.DEFAULT = "Default"
local ROOT = { profiles = true, chars = true, fights = true, learned = true }

local function Copy(v)
  if type(v) ~= "table" then
    return v
  end
  local out = {}
  for k, x in pairs(v) do
    out[k] = Copy(x)
  end
  return out
end
P.Copy = Copy

function P.CharKey()
  local name = U.Get(UnitName, "player")
  local realm = U.Get(GetRealmName)
  return string.format("%s - %s", tostring(name or "?"), tostring(realm or "?"))
end

-- Set up DMGAssistDB, migrate old flat settings, and point ns.db at this character's profile.
function P.Load(defaults)
  local root = type(DMGAssistDB) == "table" and DMGAssistDB or {}
  DMGAssistDB = root
  if type(root.profiles) ~= "table" then
    local flat = {}
    for k, v in pairs(root) do
      if not ROOT[k] then
        flat[k] = v
      end
    end
    for k in pairs(flat) do
      root[k] = nil
    end
    root.profiles = { [P.DEFAULT] = flat }
  end
  root.chars = type(root.chars) == "table" and root.chars or {}
  root.profiles[P.DEFAULT] = type(root.profiles[P.DEFAULT]) == "table" and root.profiles[P.DEFAULT] or {}
  P.defaults = defaults or P.defaults or {}
  local name = root.chars[P.CharKey()]
  if not (name and type(root.profiles[name]) == "table") then
    name = P.DEFAULT
  end
  local db = root.profiles[name]
  for k, v in pairs(P.defaults) do
    if db[k] == nil then
      db[k] = Copy(v)
    end
  end
  ns.db, ns.global, P.current = db, root, name
  return db
end

function P.List()
  local out = {}
  for name in pairs((ns.global and ns.global.profiles) or {}) do
    out[#out + 1] = name
  end
  table.sort(out, function(a, b)
    if a == P.DEFAULT then
      return true
    elseif b == P.DEFAULT then
      return false
    end
    return a < b
  end)
  return out
end

local function Changed()
  if ns.Options and ns.Options.Refresh then
    ns.Options.Refresh()
  end
  if ns.Display and ns.Display.frame then
    ns.Display.Rebuild()
  end
  if ns.Minimap then
    ns.Minimap.Apply()
  end
end

-- Switch this character to an existing profile (or create it as a copy of the current one).
function P.Use(name)
  local root = ns.global
  if not (root and type(name) == "string" and name ~= "") then
    return false
  end
  if type(root.profiles[name]) ~= "table" then
    root.profiles[name] = Copy(ns.db)
  end
  root.chars[P.CharKey()] = name ~= P.DEFAULT and name or nil
  P.Load()
  Changed()
  return true
end

-- A profile for this character only, starting from the current settings.
function P.UseCharacterProfile()
  return P.Use(P.CharKey())
end

-- Copy another profile's settings into the current one.
function P.CopyFrom(name)
  local root = ns.global
  local src = root and root.profiles[name]
  if type(src) ~= "table" or name == P.current then
    return false
  end
  local db = ns.db
  for k in pairs(db) do
    db[k] = nil
  end
  for k, v in pairs(src) do
    db[k] = Copy(v)
  end
  P.Load()
  Changed()
  return true
end

-- Delete a profile (never Default). Characters using it go back to Default.
function P.Delete(name)
  local root = ns.global
  if not root or name == P.DEFAULT or type(root.profiles[name]) ~= "table" then
    return false
  end
  root.profiles[name] = nil
  for char, p in pairs(root.chars) do
    if p == name then
      root.chars[char] = nil
    end
  end
  P.Load()
  Changed()
  return true
end
