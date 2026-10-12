-- The same small functions called with different kinds of arguments: integers, floats, strings that read as numbers, tables with
-- metamethods, nil. A call site that always sees one kind keeps a specialized copy of the callee; one that sees another kind
-- afterwards has to give way without changing the result.
local function add(a, b) return a + b end
local function mul(a, b) return a * b end
local function lt(a, b) return a < b end
local function le(a, b) return a <= b end
local function eq(a, b) return a == b end
local function cat(a, b) return a .. b end
local function neg(a) return -a end
local function len(a) return #a end
local function pick(t, k) return t[k] end
local function name(t) return t.name end
local function put(t, k, v) t[k] = v; return t end
local function setname(t, v) t.name = v end
local function band(a, b) return a & b end
local function idiv(a, b) return a // b end
local function pow(a, b) return a ^ b end
local function notf(a) return not a end

local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({n = (type(a) == "table" and a.n or a) + (type(b) == "table" and b.n or b)}, V) end
V.__lt = function(a, b) return a.n < b.n end
V.__le = function(a, b) return a.n <= b.n end
V.__eq = function(a, b) return a.n == b.n end
V.__concat = function(a, b) return "V" .. tostring(type(a) == "table" and a.n or a) .. tostring(type(b) == "table" and b.n or b) end
V.__unm = function(a) return setmetatable({n = -a.n}, V) end
V.__len = function(a) return a.n end
V.__index = function(t, k) return "idx:" .. tostring(k) end
V.__newindex = function(t, k, v) rawset(t, k, v) end
local function vec(n) return setmetatable({n = n}, V) end
local function show(v) if type(v) == "table" and getmetatable(v) == V then return "V(" .. rawget(v, "n") .. ")" end return tostring(v) end

local function sh(ok, v) return tostring(ok) .. ":" .. (ok and show(v) or tostring(v)) end

local sets = {
  {1, 2}, {3, 4}, {5, 6}, {7, 8},                                   -- integers
  {1.5, 2}, {2.5, 0.5}, {1, 2.25}, {3.0, 4.0},                       -- floats and mixes
  {"10", 5}, {"0x10", "3"}, {" 7 ", 1}, {"abc", 1}, {"1e1", "2"},    -- strings
  {vec(1), vec(2)}, {vec(3), 4}, {5, vec(6)},                        -- tables with metamethods
  {nil, 1}, {1, nil}, {true, 2}, {{}, {}},                           -- things that fail
  {2^53, 1}, {math.maxinteger, 1}, {math.mininteger, -1}, {0, 0}, {-3, 2},
  {1, 2}, {3, 4},                                                     -- integers again
}
local fns = {
  add = function(a, b) return add(a, b) end, mul = function(a, b) return mul(a, b) end, lt = function(a, b) return lt(a, b) end,
  le = function(a, b) return le(a, b) end, eq = function(a, b) return eq(a, b) end, cat = function(a, b) return cat(a, b) end,
  neg = function(a) return neg(a) end, len = function(a) return len(a) end, band = function(a, b) return band(a, b) end,
  idiv = function(a, b) return idiv(a, b) end, pow = function(a, b) return pow(a, b) end, notf = function(a) return notf(a) end,
}
local order = {"add", "mul", "lt", "le", "eq", "cat", "neg", "len", "band", "idiv", "pow", "notf"}
for round = 1, 2 do
  for _, nm in ipairs(order) do
    local out = {}
    for i, p in ipairs(sets) do
      local ok, v = pcall(fns[nm], p[1], p[2])
      out[#out + 1] = sh(ok, v):gsub("inline_types.lua:%d+: ", "")
    end
    print(nm, table.concat(out, " | "))
  end
end

print("-- the first sites see one kind of value, then another")
local function sum3(a, b, c) return add(add(a, b), c) end
for i = 1, 4 do print(sum3(i, i, i)) end
for i = 1, 4 do print(sum3(i + 0.5, i, i)) end
for i = 1, 4 do print(sum3("1", i, 2.5)) end
for i = 1, 4 do print(pcall(sum3, {}, i, 1)) end
for i = 1, 4 do print(sum3(i, i, i)) end

print("-- tables: array part, hash part, metatable index, host strings")
local arr, rec = {10, 20, 30}, {name = "rec", [100] = "far"}
local chain = setmetatable({}, {__index = {name = "inherited", [1] = "one"}})
for i = 1, 4 do
  print(pick(arr, i), pick(arr, 4 - i), pick(rec, 100), pick(rec, "name"), pick(chain, 1), pick(chain, "name"), pick("str", 1), pick(vec(i), i))
  print(name(rec), name(chain), name(vec(i)), pcall(name, nil))
  local t = put({}, i, i * 2)
  put(t, "k" .. i, i)
  print(t[i], t["k" .. i], #t)
  local o = {}
  setname(o, "x" .. i)
  print(o.name, pcall(setname, nil, 1))
end
for i = 1, 3 do print(pcall(put, nil, 1, 1)) print(pcall(put, {}, nil, 1)) print(pcall(put, {}, 0/0, 1)) end

print("-- float keys that are integers, and the sort of key in a table")
local t = {}
for i = 1, 5 do
  put(t, i + 0.0, "f" .. i)
  put(t, 2^53 + i, "big" .. i)
end
print(#t, t[1], t[3], t[2^53 + 2])
