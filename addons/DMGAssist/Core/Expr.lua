-- Expr.lua: SimC condition expressions, parsed at runtime and evaluated three-valued.
--
-- Mirrors the parser in tools/simc_import.py (same precedence, lowest first):
--   |  ^  &  comparisons (= != < <= > >=)  <? >? (MAX / MIN)  + -  * % %% (% is DIVISION in SimC, %% is modulo)
-- SimC's own tokenizer (engine/sim/expressions.cpp): "<?" is TOK_MAX and ">?" is TOK_MIN, the reverse of GCC's
-- old operators. (We had them reversed until 2026-11-08: Balance's eclipse_timings came out wrong.)
--   unary ! - +   atoms: number, identifier, ( ... ), floor(...), ceil(...)
--
-- Values are numbers (SimC is numeric: true = 1, false = 0) or E.UNKNOWN. Logic is Kleene's:
--   FALSE & UNKNOWN = FALSE, TRUE | UNKNOWN = TRUE, everything else touching UNKNOWN is UNKNOWN.
-- A parse failure makes the whole condition UNKNOWN rather than raising.

local _, ns = ...

local E = {}
ns.Expr = E

local UNKNOWN = setmetatable({}, { __tostring = function() return "UNKNOWN" end })
E.UNKNOWN = UNKNOWN

local BINARY = {
  { ["|"] = true, ["||"] = true },
  { ["^"] = true },
  { ["&"] = true, ["&&"] = true },
  { ["="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true },
  { [">?"] = true, ["<?"] = true },
  { ["+"] = true, ["-"] = true },
  { ["*"] = true, ["%"] = true, ["%%"] = true },
}
local NLEVELS = #BINARY

-- Two-character operators first so "<=" is not read as "<" "=".
local OPS2 = { ["||"] = true, ["&&"] = true, ["!="] = true, ["<="] = true, [">="] = true, [">?"] = true,
  ["<?"] = true, ["%%"] = true }
local OPS1 = { ["|"] = true, ["^"] = true, ["&"] = true, ["="] = true, ["<"] = true, [">"] = true,
  ["+"] = true, ["-"] = true, ["*"] = true, ["%"] = true, ["!"] = true, ["("] = true, [")"] = true }

local function Tokenize(s)
  local toks, pos, len = {}, 1, #s
  while pos <= len do
    local c = s:sub(pos, pos)
    if c:find("%s") then
      pos = pos + 1
    else
      local num = s:match("^%d+%.?%d*", pos)
      if num then
        toks[#toks + 1] = { "num", tonumber(num) }
        pos = pos + #num
      else
        local id = s:match("^[%a_][%w_%.]*", pos)
        if id then
          toks[#toks + 1] = { "id", id }
          pos = pos + #id
        else
          local two = s:sub(pos, pos + 1)
          if OPS2[two] then
            toks[#toks + 1] = { "op", two }
            pos = pos + 2
          elseif OPS1[c] then
            toks[#toks + 1] = { "op", c }
            pos = pos + 1
          else
            return nil, "bad character '" .. c .. "'"
          end
        end
      end
    end
  end
  return toks
end
E.Tokenize = Tokenize

-- Recursive-descent parser. Nodes: {"num", n} {"id", name} {"un", op, x} {"bin", op, a, b} {"fn", name, x}
local function Parse(s)
  local toks, err = Tokenize(s)
  if not toks then
    return nil, err
  end
  local i = 1
  local function peek()
    return toks[i]
  end
  local function isOp(t, v)
    return t ~= nil and t[1] == "op" and t[2] == v
  end

  local binary, unary, atom

  function atom()
    local t = toks[i]
    if not t then
      error("unexpected end", 0)
    end
    i = i + 1
    if t[1] == "num" then
      return { "num", t[2] }
    elseif t[1] == "id" then
      if (t[2] == "floor" or t[2] == "ceil") and isOp(peek(), "(") then
        i = i + 1
        local inner = binary(1)
        if not isOp(peek(), ")") then
          error("missing ) after " .. t[2], 0)
        end
        i = i + 1
        return { "fn", t[2], inner }
      end
      return { "id", t[2] }
    elseif isOp(t, "(") then
      local inner = binary(1)
      if not isOp(peek(), ")") then
        error("missing )", 0)
      end
      i = i + 1
      return inner
    end
    error("unexpected '" .. tostring(t[2]) .. "'", 0)
  end

  function unary()
    local t = peek()
    if t and t[1] == "op" and (t[2] == "!" or t[2] == "-" or t[2] == "+") then
      i = i + 1
      return { "un", t[2], unary() }
    end
    return atom()
  end

  function binary(level)
    if level > NLEVELS then
      return unary()
    end
    local left = binary(level + 1)
    while true do
      local t = peek()
      if t and t[1] == "op" and BINARY[level][t[2]] then
        i = i + 1
        left = { "bin", t[2], left, binary(level + 1) }
      else
        return left
      end
    end
  end

  local ok, node = pcall(binary, 1)
  if not ok then
    return nil, node
  end
  if i <= #toks then
    return nil, "unexpected '" .. tostring(toks[i][2]) .. "'"
  end
  return node
end
E.Parse = Parse

-- Parsed conditions are cached by string; a failed parse is cached as false.
local cache = {}
local failures = {}
E.failures = failures

function E.Compile(s)
  local node = cache[s]
  if node == nil then
    local err
    node, err = Parse(s)
    if not node then
      failures[s] = err
      node = false
    end
    cache[s] = node
  end
  return node
end

local function Truth(v)
  if v == UNKNOWN then
    return UNKNOWN
  end
  return v ~= 0
end

local function Num(b)
  if b then
    return 1
  end
  return 0
end

-- Decide a comparison from a known range: value in [lo, hi] compared with constant c. 1 / 0 / nil (undecided).
local function CmpRange(op, lo, hi, c)
  if op == ">=" then
    if lo >= c then return 1 end
    if hi < c then return 0 end
  elseif op == ">" then
    if lo > c then return 1 end
    if hi <= c then return 0 end
  elseif op == "<=" then
    if hi <= c then return 1 end
    if lo > c then return 0 end
  elseif op == "<" then
    if hi < c then return 1 end
    if lo >= c then return 0 end
  elseif op == "=" then
    if lo == c and hi == c then return 1 end
    if c < lo or c > hi then return 0 end
  elseif op == "!=" then
    if c < lo or c > hi then return 1 end
    if lo == c and hi == c then return 0 end
  end
  return nil
end
E.CmpRange = CmpRange

local MIRROR = { [">="] = "<=", [">"] = "<", ["<="] = ">=", ["<"] = ">", ["="] = "=", ["!="] = "!=" }

-- Evaluate a node. resolve(name) returns a number, a boolean, or UNKNOWN for an identifier.
-- bounds(name), optional, returns lo, hi for an identifier whose exact value is unknown (e.g. a hidden resource
-- narrowed down by which spells are affordable); comparisons against a constant can then still be decided.
local Eval
function Eval(node, resolve, bounds)
  local kind = node[1]
  if kind == "num" then
    return node[2]
  elseif kind == "id" then
    local v = resolve(node[2])
    if v == true then
      return 1
    elseif v == false or v == nil then
      return 0
    end
    return v
  elseif kind == "un" then
    local v = Eval(node[3], resolve, bounds)
    if v == UNKNOWN then
      return UNKNOWN
    end
    local op = node[2]
    if op == "!" then
      return Num(v == 0)
    elseif op == "-" then
      return -v
    end
    return v
  elseif kind == "fn" then
    local v = Eval(node[3], resolve, bounds)
    if v == UNKNOWN then
      return UNKNOWN
    end
    if node[2] == "floor" then
      return math.floor(v)
    end
    return math.ceil(v)
  end

  -- binary
  local op = node[2]
  if op == "&" or op == "&&" then
    local a = Truth(Eval(node[3], resolve, bounds))
    if a == false then
      return 0
    end
    local b = Truth(Eval(node[4], resolve, bounds))
    if b == false then
      return 0
    end
    if a == UNKNOWN or b == UNKNOWN then
      return UNKNOWN
    end
    return 1
  elseif op == "|" or op == "||" then
    local a = Truth(Eval(node[3], resolve, bounds))
    if a == true then
      return 1
    end
    local b = Truth(Eval(node[4], resolve, bounds))
    if b == true then
      return 1
    end
    if a == UNKNOWN or b == UNKNOWN then
      return UNKNOWN
    end
    return 0
  end

  local a = Eval(node[3], resolve, bounds)
  local b = Eval(node[4], resolve, bounds)
  if a == UNKNOWN or b == UNKNOWN then
    if bounds and MIRROR[op] then
      local idNode, c, cmp = nil, nil, op
      if a == UNKNOWN and b ~= UNKNOWN and node[3][1] == "id" then
        idNode, c = node[3], b
      elseif b == UNKNOWN and a ~= UNKNOWN and node[4][1] == "id" then
        idNode, c, cmp = node[4], a, MIRROR[op]
      end
      if idNode then
        local lo, hi = bounds(idNode[2])
        if lo and hi then
          local r = CmpRange(cmp, lo, hi, c)
          if r then
            return r
          end
        end
      end
    end
    return UNKNOWN
  end
  if op == "^" then
    return Num((a ~= 0) ~= (b ~= 0))
  elseif op == "=" then
    return Num(a == b)
  elseif op == "!=" then
    return Num(a ~= b)
  elseif op == "<" then
    return Num(a < b)
  elseif op == "<=" then
    return Num(a <= b)
  elseif op == ">" then
    return Num(a > b)
  elseif op == ">=" then
    return Num(a >= b)
  elseif op == "<?" then
    return math.max(a, b) -- SimC: a<?b is the larger
  elseif op == ">?" then
    return math.min(a, b) -- SimC: a>?b is the smaller
  elseif op == "+" then
    return a + b
  elseif op == "-" then
    return a - b
  elseif op == "*" then
    return a * b
  elseif op == "%" then
    if b == 0 then
      return 0
    end
    return a / b
  elseif op == "%%" then
    if b == 0 then
      return 0
    end
    return math.fmod(a, b)
  end
  return UNKNOWN
end
E.Eval = Eval

-- Evaluate a condition string to TRUE (true), FALSE (false) or UNKNOWN. Empty/nil condition is TRUE.
function E.Test(cond, resolve, bounds)
  if cond == nil or cond == "" then
    return true
  end
  local node = E.Compile(cond)
  if not node then
    return UNKNOWN
  end
  return Truth(Eval(node, resolve, bounds))
end
E.Truth = Truth

-- Evaluate a condition string to a number or UNKNOWN (for variable values).
function E.Value(expr, resolve, bounds)
  if expr == nil or expr == "" then
    return 0
  end
  local node = E.Compile(expr)
  if not node then
    return UNKNOWN
  end
  return Eval(node, resolve, bounds)
end
