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

-- The report: everything needed to debug, sized to paste into a chat. Errors (stacks trimmed), the latest
-- launch snapshot, the latest login and combat probes, the latest fights, recent notes. `keep` sets how much
-- history goes in (Encode lowers it until the string fits REPORT_LIMIT).
X.REPORT_LIMIT = 30000
local DEFAULT_KEEP = { sessions = 4, notes = 120, probes = 2, stack = 900, events = 2000 }

-- Fights with only their newest `n` events (a long fight can be most of the report on its own).
local function TrimSessions(sessions, n)
  local out = {}
  for i, s in ipairs(sessions) do
    if #(s.events or {}) > n then
      local c = {}
      for k, v in pairs(s) do
        c[k] = v
      end
      c.events = Tail(s.events, n)
      c.eventsCut = #s.events - n
      out[i] = c
    else
      out[i] = s
    end
  end
  return out
end

local function TrimErrors(errors, stackLen)
  local out = {}
  for i, e in ipairs(errors) do
    local c = {}
    for k, v in pairs(e) do
      c[k] = v
    end
    if type(c.stack) == "string" and #c.stack > stackLen then
      c.stack = string.sub(c.stack, 1, stackLen) .. "..."
    end
    out[i] = c
  end
  return out
end

function X.Build(keep)
  local db = ns.db
  if not db then
    return nil
  end
  keep = keep or DEFAULT_KEEP
  ns.Errors.PullBugGrabber()
  return {
    format = "dmgassist-watchdog",
    schema = ns.SCHEMA,
    watchdogVersion = ns.VERSION,
    exportedAt = date("%Y-%m-%d %H:%M:%S"),
    loginCount = db.loginCount,
    counters = db.counters,
    settings = db.settings,
    errors = TrimErrors(Tail(db.errors, 30), keep.stack),
    sessions = TrimSessions(Tail(db.sessions, keep.sessions), keep.events),
    probes = Tail(db.probes, keep.probes),
    notes = Tail(db.notes, keep.notes),
    launch = Tail(db.launch or {}, 1),
    trimmed = keep ~= DEFAULT_KEEP or nil,
  }
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

local function EncodeData(data)
  local enc = C_EncodingUtil
  if enc and enc.SerializeJSON and enc.CompressString and enc.EncodeBase64 then
    local okJ, json = pcall(enc.SerializeJSON, data, { ignoreSerializationErrors = true })
    if okJ and type(json) == "string" then
      local method = Enum and Enum.CompressionMethod and Enum.CompressionMethod.Deflate or 0
      local okC, compressed = pcall(enc.CompressString, json, method)
      if okC and type(compressed) == "string" then
        local okB, b64 = pcall(enc.EncodeBase64, compressed)
        if okB and type(b64) == "string" then
          return "DMGW1:" .. b64, "json+deflate+base64"
        end
      end
    end
  end
  return "DMGW0:" .. X.ToLua(data), "lua"
end

-- Returns reportString, formatTag, length  (or nil, errorMessage). Fewer fights / notes go in until it fits.
function X.Encode()
  local keep = {}
  for k, v in pairs(DEFAULT_KEEP) do
    keep[k] = v
  end
  local first = true
  while true do
    local data = X.Build(first and DEFAULT_KEEP or keep)
    if not data then
      return nil, "database not ready"
    end
    local str, fmt = EncodeData(data)
    local small = keep.sessions <= 1 and keep.notes <= 20 and keep.probes <= 1 and keep.stack <= 300
      and keep.events <= 60
    if #str <= X.REPORT_LIMIT or small then
      return str, fmt, #str
    end
    first = false
    if keep.sessions > 1 then
      keep.sessions = keep.sessions - 1
    elseif keep.notes > 20 then
      keep.notes = math.floor(keep.notes / 2)
    elseif keep.probes > 1 then
      keep.probes = 1
    elseif keep.stack > 300 then
      keep.stack = 300
    else
      keep.events = math.max(60, math.floor(math.min(keep.events, 1500) / 2))
    end
  end
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
  add("To share: /dmgw, then Ctrl+C and paste it into the chat. No /reload needed.")
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
