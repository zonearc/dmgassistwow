-- Expr.lua: SimC condition expressions, parsed at runtime and evaluated three-valued.
--
-- Mirrors the parser in tools/simc_import.py (same precedence, lowest first):
--   |  ^  &  comparisons (= != < <= > >=)  <? >? (MAX / MIN)  + -  * % %% (% is DIVISION in SimC, %% is modulo)
-- SimC's own tokenizer (engine/sim/expressions.cpp): "<?" is TOK_MAX and ">?" is TOK_MIN, the reverse of GCC's
-- old operators. (We had them reversed until 2026-11-08: Balance's eclipse_timings came out wrong.)
--   unary ! - +   atoms: number, identifier, ( ... ), floor(...), ceil(...)
--
-- Values are numbers (SimC is numeric: true = 1, false = 0) or E.UNKNOWN. Logic is Kleene's:
--   FALSE & UNKNOWN = FALSE, TRUE | UNKNOWN = TRUE. Unknown values keep their known limits (see Ranges), so
--   arithmetic and comparisons on them are decided whenever the limits allow.
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

-- Ranges. An unknown value often still has known limits: "buff.x.up" is 0 or 1, a remaining time is never
-- negative, a hidden resource is narrowed down by bounds(name). Inside an evaluation such a value is a range
-- { lo, hi } and arithmetic, MAX / MIN and comparisons work on the limits, so "the longest of these cooldowns
-- < 1" is decided as soon as one known term is >= 1, or every term is certainly < 1, even when another term
-- mixes in a hidden proc. UNKNOWN is the range with no limits. Outside Eval a range is reported as UNKNOWN.
local INF = math.huge
local RANGE = {}

local function Range(lo, hi)
  if lo ~= lo or hi ~= hi then -- NaN
    return UNKNOWN
  end
  if lo == hi then
    return lo
  end
  if lo == -INF and hi == INF then
    return UNKNOWN
  end
  return setmetatable({ lo, hi }, RANGE)
end

local function Lim(v)
  if v == UNKNOWN then
    return -INF, INF
  elseif type(v) == "table" then
    return v[1], v[2]
  end
  return v, v
end

local function Exact(v)
  return type(v) == "number"
end

local function Truth(v)
  if type(v) == "number" then
    return v ~= 0
  end
  local lo, hi = Lim(v)
  if lo > 0 or hi < 0 then
    return true
  elseif lo == 0 and hi == 0 then
    return false
  end
  return UNKNOWN
end

local function Num(b)
  if b then
    return 1
  end
  return 0
end

-- Limits of an identifier whose value is unknown, from the shape of its name (SimC's conventions).
local FLAG_SUFFIX = { up = true, down = true, ticking = true, refreshable = true, enabled = true, ready = true }
local FLAG_HEAD = { talent = true, hero_tree = true, prev_gcd = true, prev = true, prev_off_gcd = true,
  set_bonus = true }
local NONNEG_SUFFIX = { remains = true, duration = true, stack = true, react = true, deficit = true,
  charges = true, charges_fractional = true, recharge_time = true, full_recharge_time = true,
  time_to_die = true, max_stack = true, elapsed = true }
local NONNEG_NAME = { fight_remains = true, time = true, active_enemies = true, spell_targets = true }

local function ShapeLimits(name)
  local head = name:match("^([%w_]+)")
  local last = name:match("([%w_]+)$")
  if FLAG_SUFFIX[last] or FLAG_HEAD[head] then
    return 0, 1
  end
  if NONNEG_SUFFIX[last] or NONNEG_NAME[name] or head == "active_dot" or head == "active_dots"
    or name:find("^spell_targets%.") then
    return 0, INF
  end
  return nil
end
E.ShapeLimits = ShapeLimits

local function Mul(alo, ahi, blo, bhi)
  local function m(x, y)
    if x == 0 or y == 0 then
      return 0 -- 0 * anything is 0, also against an unlimited side
    end
    return x * y
  end
  local p1, p2, p3, p4 = m(alo, blo), m(alo, bhi), m(ahi, blo), m(ahi, bhi)
  return math.min(p1, p2, p3, p4), math.max(p1, p2, p3, p4)
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

-- Compare two ranges: 1 / 0 / UNKNOWN-as-range.
local function Compare(op, alo, ahi, blo, bhi)
  local r
  if op == "<" then
    if ahi < blo then r = 1 elseif alo >= bhi then r = 0 end
  elseif op == "<=" then
    if ahi <= blo then r = 1 elseif alo > bhi then r = 0 end
  elseif op == ">" then
    if alo > bhi then r = 1 elseif ahi <= blo then r = 0 end
  elseif op == ">=" then
    if alo >= bhi then r = 1 elseif ahi < blo then r = 0 end
  elseif op == "=" then
    if alo == ahi and blo == bhi and alo == blo then r = 1 elseif ahi < blo or bhi < alo then r = 0 end
  elseif op == "!=" then
    if ahi < blo or bhi < alo then r = 1 elseif alo == ahi and blo == bhi and alo == blo then r = 0 end
  end
  if r then
    return r
  end
  return Range(0, 1)
end

local COMPARE = { ["="] = true, ["!="] = true, ["<"] = true, ["<="] = true, [">"] = true, [">="] = true }

-- Evaluate a node. resolve(name) returns a number, a boolean, or UNKNOWN for an identifier.
-- bounds(name), optional, returns lo, hi for an identifier whose exact value is unknown (e.g. a hidden resource
-- narrowed down by which spells are affordable). Returns a number, a range (inside) or UNKNOWN.
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
    if v == UNKNOWN then
      local lo, hi
      if bounds then
        lo, hi = bounds(node[2])
      end
      local slo, shi = ShapeLimits(node[2])
      if lo and hi then
        if slo then
          lo, hi = math.max(lo, slo), math.min(hi, shi)
        end
        return Range(lo, hi)
      elseif slo then
        return Range(slo, shi)
      end
    end
    return v
  elseif kind == "un" then
    local v = Eval(node[3], resolve, bounds)
    local op = node[2]
    if op == "!" then
      local t = Truth(v)
      if t == UNKNOWN then
        return Range(0, 1)
      end
      return Num(not t)
    elseif op == "-" then
      if Exact(v) then
        return -v
      end
      local lo, hi = Lim(v)
      return Range(-hi, -lo)
    end
    return v
  elseif kind == "fn" then
    local v = Eval(node[3], resolve, bounds)
    local f = node[2] == "floor" and math.floor or math.ceil
    if Exact(v) then
      return f(v)
    end
    local lo, hi = Lim(v)
    return Range(f(lo), f(hi))
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
      return Range(0, 1)
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
      return Range(0, 1)
    end
    return 0
  end

  local a = Eval(node[3], resolve, bounds)
  local b = Eval(node[4], resolve, bounds)
  if Exact(a) and Exact(b) then
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

  -- At least one side is a range.
  local alo, ahi = Lim(a)
  local blo, bhi = Lim(b)
  if COMPARE[op] then
    return Compare(op, alo, ahi, blo, bhi)
  elseif op == "^" then
    local ta, tb = Truth(a), Truth(b)
    if ta == UNKNOWN or tb == UNKNOWN then
      return Range(0, 1)
    end
    return Num(ta ~= tb)
  elseif op == "<?" then
    return Range(math.max(alo, blo), math.max(ahi, bhi))
  elseif op == ">?" then
    return Range(math.min(alo, blo), math.min(ahi, bhi))
  elseif op == "+" then
    return Range(alo + blo, ahi + bhi)
  elseif op == "-" then
    return Range(alo - bhi, ahi - blo)
  elseif op == "*" then
    return Range(Mul(alo, ahi, blo, bhi))
  elseif op == "%" then
    if blo > 0 or bhi < 0 then
      return Range(Mul(alo, ahi, 1 / bhi, 1 / blo))
    end
    return UNKNOWN
  end
  return UNKNOWN
end

-- Eval for callers outside this file: a range is reported as UNKNOWN (Truth still decides it).
local function Outer(v)
  if type(v) == "table" and getmetatable(v) == RANGE then
    return UNKNOWN
  end
  return v
end

function E.Eval(node, resolve, bounds)
  local v = Eval(node, resolve, bounds)
  local t = type(v) == "table" and getmetatable(v) == RANGE and Truth(v)
  if t == true or t == false then
    return v -- a decided truth: keep the range so Truth() sees it
  end
  return Outer(v)
end

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
  return Outer(Eval(node, resolve, bounds))
end
