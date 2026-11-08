-- Export.lua: turn the database into one string that can be copied out of the
-- game and pasted for analysis.
--
-- Preferred format (when C_EncodingUtil exists, verified on Forever 1.60.1 and
-- Mainline 12.1.5):   "DMGW1:" .. base64( deflate( json ) )
-- Fallback:           "DMGW0:" .. a Lua table literal (uncompressed)
--
-- Decode on a PC with tools/decode-export.py. The SavedVariables file
-- (WTF/Account/<ACCOUNT>/SavedVariables/DMGAssist_Watchdog.lua) contains the
-- same data and is the easier route when you can upload files.

local _, ns = ...

local X = {}
ns.Export = X

local function Tail(list, n)
  local out = {}
  local first = math.max(1, #list - n + 1)
  for i = first, #list do
    out[#out + 1] = list[i]
  end
  return out
end

-- scope: "all" (default) or "last" (latest probe + latest session + errors)
function X.Build(scope)
  local db = ns.db
  if not db then
    return nil
  end
  ns.Errors.PullBugGrabber()
  local data = {
    format = "dmgassist-watchdog",
    schema = ns.SCHEMA,
    watchdogVersion = ns.VERSION,
    exportedAt = date("%Y-%m-%d %H:%M:%S"),
    loginCount = db.loginCount,
    counters = db.counters,
    settings = db.settings,
    errors = db.errors,
  }
  if scope == "last" then
    data.sessions = Tail(db.sessions, 1)
    data.probes = Tail(db.probes, 2)
    data.notes = Tail(db.notes, 60)
    data.launch = Tail(db.launch or {}, 1)
  else
    data.sessions = db.sessions
    data.probes = db.probes
    data.notes = db.notes
    data.launch = db.launch
  end
  return data
end

-- Minimal Lua-literal serializer for the fallback path.
local function Serialize(value, depth, out)
  local t = type(value)
  if t == "table" then
    if depth > 12 then
      out[#out + 1] = '"<depth>"'
      return
    end
    out[#out + 1] = "{"
    for k, v in pairs(value) do
      if type(k) == "string" then
        out[#out + 1] = string.format("[%q]=", k)
      else
        out[#out + 1] = "[" .. tostring(k) .. "]="
      end
      Serialize(v, depth + 1, out)
      out[#out + 1] = ","
    end
    out[#out + 1] = "}"
  elseif t == "string" then
    out[#out + 1] = string.format("%q", value)
  elseif t == "number" or t == "boolean" then
    out[#out + 1] = tostring(value)
  else
    out[#out + 1] = "nil"
  end
end

function X.ToLua(data)
  local out = {}
  Serialize(data, 0, out)
  return table.concat(out)
end

-- Returns exportString, formatTag, byteLength  (or nil, errorMessage)
function X.Encode(scope)
  local data = X.Build(scope)
  if not data then
    return nil, "database not ready"
  end
  local enc = C_EncodingUtil
  if enc and enc.SerializeJSON and enc.CompressString and enc.EncodeBase64 then
    local okJ, json = pcall(enc.SerializeJSON, data, { ignoreSerializationErrors = true })
    if okJ and type(json) == "string" then
      local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate or 0
      local okC, compressed = pcall(enc.CompressString, json, method)
      if okC and type(compressed) == "string" then
        local okB, b64 = pcall(enc.EncodeBase64, compressed)
        if okB and type(b64) == "string" then
          return "DMGW1:" .. b64, "json+deflate+base64", #b64
        end
      end
    end
  end
  local lua = X.ToLua(data)
  return "DMGW0:" .. lua, "lua", #lua
end

-- One-screen text summary for the viewer and /dmgw status.
function X.Summary()
  local db = ns.db
  if not db then
    return "Database not loaded yet."
  end
  local lines = {}
  local function add(fmt, ...)
    lines[#lines + 1] = string.format(fmt, ...)
  end
  add("DMGAssist Watchdog %s   logins: %d", ns.VERSION, db.loginCount or 0)
  if type(_G.BugGrabber) == "table" then
    add("Errors: read from BugGrabber (BugSack keeps the error handler)")
  else
    add("Error handler installed: %s", tostring(ns.Errors.IsInstalled()))
  end
  add("Errors: %d unique   Sessions: %d   Probes: %d", #db.errors, #db.sessions, #db.probes)
  local probe = ns.Probe.Latest()
  if probe then
    local env, f = probe.env or {}, probe.features or {}
    add("")
    add("Latest probe (%s, %s)", tostring(probe.label), tostring(probe.when))
    add("  Build %s (%s)  interface %s  class %s  spec %s", tostring(env.version), tostring(env.build),
      tostring(env.interface), tostring(env.class), tostring(env.specName))
    add("  Assisted Combat available: %s  %s", tostring(f.assistedCombatAvailable),
      f.assistedCombatFailureReason and ("(" .. tostring(f.assistedCombatFailureReason) .. ")") or "")
    add("  Cooldown Manager available: %s", tostring(f.cooldownViewerAvailable))
    add("  Spells probed: %d %s", probe.spells and #probe.spells or 0, probe.spellNote or "")
    local secretCd, secretAura = 0, 0
    for _, row in ipairs(probe.spells or {}) do
      if row.cdSecret == true then
        secretCd = secretCd + 1
      end
      if row.auraSecret == true then
        secretAura = secretAura + 1
      end
    end
    add("  Secret cooldowns: %d   secret auras: %d", secretCd, secretAura)
  else
    add("No probe yet. Type /dmgw probe")
  end
  add("")
  add("To share: press 'Copy report', then Ctrl+C and paste it into the chat. No /reload needed.")
  local last = db.sessions[#db.sessions]
  if last then
    add("")
    add("Last fight: %s, %.0f s in %s, %d events%s", tostring(last.when), tonumber(last.duration) or 0,
      tostring(last.zone), #(last.events or {}), (last.dropped or 0) > 0 and (" (" .. last.dropped .. " dropped)") or "")
    local perf = last.perf and last.perf.DMGAssist
    if perf then
      add("  DMGAssist CPU: %.2f ms average, %.1f ms peak", perf.recentAvgMs or 0, perf.peakMs or 0)
    end
  end
  local notes = Tail(db.notes, 12)
  if #notes > 0 then
    add("")
    add("Latest DMGAssist notes:")
    for i = #notes, 1, -1 do
      local n = notes[i]
      local d = n.data
      local text = type(d) == "table" and (tostring(d.kind or "") .. " " .. tostring(d.data or "")) or tostring(d)
      add("  %s %s %s", tostring(n.when), tostring(n.kind), string.sub(text, 1, 110))
    end
  end
  ns.Errors.PullBugGrabber()
  local recent = Tail(db.errors, 5)
  if #recent > 0 then
    add("")
    add("Most recent errors:")
    for i = #recent, 1, -1 do
      local e = recent[i]
      add("  [%s x%d%s%s] %s", tostring(e.kind), e.count or 1, e.ours and " OURS" or "",
        e.source and (" via " .. e.source) or "",
        string.sub(tostring(e.msg), 1, 120))
    end
  end
  return table.concat(lines, "\n")
end
