-- SpellMap.lua: SimC action/buff names <-> the player's spell IDs and talents.
--
-- SimC names a spell by tokenizing its English name: lower case, spaces to "_", punctuation dropped
-- ("Tiger's Fury" -> "tigers_fury"). We build the same tokens from the player's spellbook and talent tree
-- (read out of combat on SPELLS_CHANGED / talent events), so the data needs no spell IDs.
--
-- Spellbook: C_SpellBook.GetNumSpellBookSkillLines / GetSpellBookSkillLineInfo / GetSpellBookItemInfo.
-- Talents:   C_ClassTalents.GetActiveConfigID, C_Traits.GetConfigInfo(.treeIDs) / GetTreeNodes / GetNodeInfo
--            (.activeEntry.entryID, .activeRank, .subTreeID, .subTreeActive) / GetEntryInfo(.definitionID) /
--            GetDefinitionInfo(.spellID), C_ClassTalents.GetActiveHeroTalentSpec -> GetSubTreeInfo(.name).
-- All verified in Blizzard_APIDocumentationGenerated on forever 1.60.1 and live 12.1.5.
--
-- Names that only exist in SimC (aliases like "bs_inc", form-specific "_cat" suffixes) are resolved through a
-- small alias table and generic suffix stripping; anything still unresolved is reported, never guessed.

local _, ns = ...
local U = ns.U

local M = {}
ns.SpellMap = M

M.spells = {}     -- token -> spellID (active spells in the spellbook, current spec)
M.passives = {}   -- token -> spellID (passive spellbook entries)
M.talents = {}    -- token -> rank (0 = in the tree but not taken)
M.talentSpell = {} -- token -> spellID
M.heroTree = nil  -- token of the active hero tree
M.talentsRead = false
M.unresolved = {}

-- SimC-only names. Values are lists of tokens to try in order.
M.ALIASES = {
  bs_inc = { "incarnation_avatar_of_ashamane", "berserk" },
  ca_inc = { "incarnation_chosen_of_elune", "celestial_alignment" },
  incarnation = { "incarnation_avatar_of_ashamane", "incarnation_chosen_of_elune", "incarnation_guardian_of_ursoc",
    "incarnation_tree_of_life" },
  bloodlust = { "bloodlust", "heroism", "time_warp", "primal_rage", "fury_of_the_aspects" },
}

-- Generic suffixes SimC adds to tell variants apart ("moonfire_cat", "swipe_bear", "rend_dot").
local SUFFIXES = { "_cat", "_bear", "_dot", "_debuff", "_buff", "_aoe", "_st" }

function M.Token(name)
  if type(name) ~= "string" then
    return nil
  end
  local t = name:lower():gsub("[%s%-]+", "_"):gsub("[^%w_]", "")
  return t
end

function M.Candidates(token)
  local list = { token }
  local alias = M.ALIASES[token]
  if alias then
    for _, a in ipairs(alias) do
      list[#list + 1] = a
    end
  end
  for _, suffix in ipairs(SUFFIXES) do
    if token:sub(-#suffix) == suffix then
      list[#list + 1] = token:sub(1, -#suffix - 1)
    end
  end
  return list
end

-- Active spell ID for a SimC action token, or nil.
function M.SpellID(token)
  for _, t in ipairs(M.Candidates(token)) do
    local id = M.spells[t]
    if id then
      return id
    end
  end
  M.unresolved[token] = true
  return nil
end

-- Any spell ID (active, passive, or talent) for a token; used for buffs and dots named after spells.
function M.AnySpellID(token)
  for _, t in ipairs(M.Candidates(token)) do
    local id = M.spells[t] or M.passives[t] or M.talentSpell[t]
    if id then
      return id
    end
  end
  return nil
end

-- Talent rank for a token: number (0 = not taken), or nil when the talent tree could not be read
-- or the name is not in it.
function M.TalentRank(token)
  if not M.talentsRead then
    return nil
  end
  for _, t in ipairs(M.Candidates(token)) do
    local r = M.talents[t]
    if r then
      return r
    end
  end
  return nil
end

local function ScanSpellbook()
  local spells, passives = {}, {}
  local n = U.Read(U.Call(C_SpellBook and C_SpellBook.GetNumSpellBookSkillLines))
  if type(n) ~= "number" then
    return false
  end
  local bank = (Enum and Enum.SpellBookSpellBank and Enum.SpellBookSpellBank.Player) or 0
  for line = 1, n do
    local info = U.Read(U.Call(C_SpellBook.GetSpellBookSkillLineInfo, line))
    if type(info) == "table" and not U.Read(info.isGuild) and not U.Read(info.offSpecID) then
      local offset, count = U.Read(info.itemIndexOffset), U.Read(info.numSpellBookItems)
      if type(offset) == "number" and type(count) == "number" then
        for slot = offset + 1, offset + count do
          local item = U.Read(U.Call(C_SpellBook.GetSpellBookItemInfo, slot, bank))
          if type(item) == "table" then
            local id, name = U.Read(item.spellID), U.Read(item.name)
            local token = M.Token(name)
            if type(id) == "number" and token and token ~= "" and not U.Read(item.isOffSpec) then
              if U.Read(item.isPassive) then
                passives[token] = id
              else
                spells[token] = id
                -- Overridden spells keep the base name reachable too (Moonfire -> Moonfire in cat form, etc.).
                local base = U.Read(item.actionID)
                if type(base) == "number" and base ~= id then
                  local baseName = U.Read(U.Call(C_Spell and C_Spell.GetSpellName, base))
                  local bt = M.Token(baseName)
                  if bt and bt ~= "" and not spells[bt] then
                    spells[bt] = base
                  end
                end
              end
            end
          end
        end
      end
    end
  end
  M.spells, M.passives = spells, passives
  return true
end

local function ScanTalents()
  local talents, talentSpell = {}, {}
  local configID = U.Read(U.Call(C_ClassTalents and C_ClassTalents.GetActiveConfigID))
  if type(configID) ~= "number" then
    return false
  end
  local config = U.Read(U.Call(C_Traits and C_Traits.GetConfigInfo, configID))
  if type(config) ~= "table" or type(config.treeIDs) ~= "table" then
    return false
  end
  for _, treeID in ipairs(config.treeIDs) do
    local nodes = U.Read(U.Call(C_Traits.GetTreeNodes, treeID))
    if type(nodes) == "table" then
      for _, nodeID in ipairs(nodes) do
        local node = U.Read(U.Call(C_Traits.GetNodeInfo, configID, nodeID))
        if type(node) == "table" and type(node.entryIDs) == "table" then
          local activeEntry = type(node.activeEntry) == "table" and U.Read(node.activeEntry.entryID) or nil
          local rank = U.Read(node.activeRank)
          if type(rank) ~= "number" then
            rank = 0
          end
          -- A hero-tree node only counts while its hero tree is the active one.
          if U.Read(node.subTreeID) and U.Read(node.subTreeActive) == false then
            rank = 0
          end
          for _, entryID in ipairs(node.entryIDs) do
            local entry = U.Read(U.Call(C_Traits.GetEntryInfo, configID, entryID))
            local defID = type(entry) == "table" and U.Read(entry.definitionID) or nil
            local def = defID and U.Read(U.Call(C_Traits.GetDefinitionInfo, defID)) or nil
            local spellID = type(def) == "table" and U.Read(def.spellID) or nil
            if type(spellID) == "number" then
              local token = M.Token(U.Read(U.Call(C_Spell and C_Spell.GetSpellName, spellID)))
              if token and token ~= "" then
                local r = 0
                if entryID == activeEntry then
                  r = rank
                end
                if (talents[token] or 0) < r or talents[token] == nil then
                  talents[token] = r
                end
                talentSpell[token] = spellID
              end
            end
          end
        end
      end
    end
  end
  M.talents, M.talentSpell = talents, talentSpell
  M.heroTree = nil
  local hero = U.Read(U.Call(C_ClassTalents.GetActiveHeroTalentSpec))
  if type(hero) == "number" then
    local sub = U.Read(U.Call(C_Traits.GetSubTreeInfo, configID, hero))
    if type(sub) == "table" then
      M.heroTree = M.Token(U.Read(sub.name))
    end
  end
  return true
end

M.byID = {}

function M.TokenForID(id)
  local t = M.byID[id]
  if t then
    return t
  end
  t = M.Token(U.Read(U.Call(C_Spell and C_Spell.GetSpellName, id)))
  if t and t ~= "" then
    M.byID[id] = t
    return t
  end
  return nil
end

-- Rebuild everything. Call out of combat (talents/spellbook don't change in combat anyway).
function M.Refresh()
  local okBook = ScanSpellbook()
  M.talentsRead = ScanTalents()
  M.unresolved = {}
  M.byID = {}
  local n = 0
  for token, id in pairs(M.passives) do
    M.byID[id] = token
  end
  for token, id in pairs(M.spells) do
    M.byID[id] = token
    n = n + 1
  end
  M.count = n
  return okBook
end
