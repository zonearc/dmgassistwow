-- api_snapshot.lua: snapshot Blizzard's API documentation for the functions/events we depend on.
--
-- Usage: lua5.1 tools/api_snapshot.lua <ui-source-root> <watchlist> <out.json>
--   <ui-source-root> holds forever/ and live/ checkouts of Gethe/wow-ui-source
--
-- Loads every Blizzard_APIDocumentationGenerated/*.lua file with a stub APIDocumentation object (the files
-- are plain Lua tables), then writes, per branch, the full documentation entry for each watched name.
-- Output is deterministic (sorted keys) so a diff means Blizzard changed something.

local root, watchPath, outPath = arg[1], arg[2], arg[3]
assert(root and watchPath and outPath, "usage: api_snapshot.lua <ui-source-root> <watchlist> <out.json>")

local function autoTable()
  local t = {}
  setmetatable(t, {
    __index = function(self, k)
      local child = autoTable()
      rawset(self, k, child)
      return child
    end,
  })
  return t
end

local function readWatchlist(path)
  local names = {}
  for line in io.lines(path) do
    line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if line ~= "" then
      names[#names + 1] = line
    end
  end
  return names
end

local function listDir(dir)
  local files = {}
  local p = io.popen('ls "' .. dir .. '"')
  for f in p:lines() do
    if f:match("Documentation%.lua$") then
      files[#files + 1] = f
    end
  end
  p:close()
  table.sort(files)
  return files
end

local function loadDocs(dir)
  local systems = {}
  local env = setmetatable({}, { __index = _G })
  env.Enum = autoTable()
  env.Constants = autoTable()
  env.APIDocumentation = {
    AddDocumentationTable = function(_, t)
      systems[#systems + 1] = t
    end,
  }
  for _, f in ipairs(listDir(dir)) do
    local chunk, err = loadfile(dir .. "/" .. f)
    if chunk then
      setfenv(chunk, env)
      local ok, runErr = pcall(chunk)
      if not ok then
        io.stderr:write("skip " .. f .. ": " .. tostring(runErr) .. "\n")
      end
    else
      io.stderr:write("skip " .. f .. ": " .. tostring(err) .. "\n")
    end
  end
  -- Index functions by "Namespace.Name" (or bare name) and events by LiteralName.
  local index = {}
  for _, sys in ipairs(systems) do
    for _, fn in ipairs(sys.Functions or {}) do
      local key = sys.Namespace and (sys.Namespace .. "." .. fn.Name) or fn.Name
      index[key] = fn
    end
    for _, ev in ipairs(sys.Events or {}) do
      if ev.LiteralName then
        index[ev.LiteralName] = ev
      end
    end
  end
  return index
end

-- Strip auto-vivified Enum stubs (tables with no content) and keep only plain data.
local function clean(v, depth)
  depth = depth or 0
  local t = type(v)
  if t == "table" then
    if depth > 8 then
      return nil
    end
    local out, n = {}, 0
    for k, x in pairs(v) do
      local c = clean(x, depth + 1)
      if c ~= nil then
        out[k] = c
        n = n + 1
      end
    end
    if n == 0 then
      return nil
    end
    return out
  elseif t == "string" or t == "number" or t == "boolean" then
    return v
  end
  return nil
end

local function json(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "table" then
    local isArray = #v > 0
    local keys = {}
    if isArray then
      for i = 1, #v do
        keys[i] = i
      end
    else
      for k in pairs(v) do
        keys[#keys + 1] = k
      end
      table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
      end)
    end
    local inner = indent .. "  "
    local parts = {}
    for _, k in ipairs(keys) do
      local val = json(v[k], inner)
      if isArray then
        parts[#parts + 1] = inner .. val
      else
        parts[#parts + 1] = inner .. string.format("%q", tostring(k)) .. ": " .. val
      end
    end
    local open, close = isArray and "[" or "{", isArray and "]" or "}"
    return open .. "\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. close
  elseif t == "string" then
    return (string.format("%q", v):gsub("\\\n", "\\n"))
  elseif t == "number" or t == "boolean" then
    return tostring(v)
  end
  return "null"
end

local function buildInfo(dir)
  local p = io.popen('git -C "' .. dir .. '" log -1 --format="%cs %s" 2>/dev/null')
  local s = p:read("*l") or "unknown"
  p:close()
  return s
end

local names = readWatchlist(watchPath)
local snapshot = { watchlist = names, branches = {} }
for _, branch in ipairs({ "forever", "live" }) do
  local dir = root .. "/" .. branch .. "/Interface/AddOns/Blizzard_APIDocumentationGenerated"
  local index = loadDocs(dir)
  local entries = {}
  for _, name in ipairs(names) do
    entries[name] = clean(index[name]) or "MISSING"
  end
  snapshot.branches[branch] = { source = buildInfo(root .. "/" .. branch), entries = entries }
end

local fh = assert(io.open(outPath, "w"))
fh:write(json(snapshot), "\n")
fh:close()
for _, branch in ipairs({ "forever", "live" }) do
  local missing = {}
  for name, e in pairs(snapshot.branches[branch].entries) do
    if e == "MISSING" then
      missing[#missing + 1] = name
    end
  end
  table.sort(missing)
  print(branch .. ": " .. snapshot.branches[branch].source .. "; missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none"))
end
