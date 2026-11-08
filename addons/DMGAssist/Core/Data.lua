-- Data.lua: registry the generated Data\<branch>\*.lua files feed into.
--
-- The .toc gates each branch's files by game type, so normally only the running client's data loads.
-- The registry is still keyed by branch so a gating surprise is detected instead of silently using the
-- wrong game's priorities.

local _, ns = ...

local D = {}
ns.Data = D

D.specs = {}   -- [branch][specKey] = record (see tools/simc_import.py)
D.index = {}   -- [branch] = { branch, commit, date, specs = {...} }

function ns.RegisterSpecData(branch, key, record)
  D.specs[branch] = D.specs[branch] or {}
  D.specs[branch][key] = record
end

function ns.RegisterDataIndex(index)
  D.index[index.branch] = index
end

function D.LoadedBranches()
  local out = {}
  for branch in pairs(D.index) do
    out[#out + 1] = branch
  end
  table.sort(out)
  return out
end

function D.Get(branch, key)
  local byBranch = branch and D.specs[branch]
  return byBranch and byBranch[key] or nil
end

function D.Source(branch)
  return D.index[branch]
end
