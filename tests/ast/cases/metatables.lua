local function show(...) print(...) end
local V = {}
V.__index = V
V.__add = function(a, b) return setmetatable({x = a.x + b.x, y = a.y + b.y}, V) end
V.__sub = function(a, b) return setmetatable({x = a.x - b.x, y = a.y - b.y}, V) end
V.__mul = function(a, b) if type(a) == "number" then return setmetatable({x = a * b.x, y = a * b.y}, V) end return a.x * b.x + a.y * b.y end
V.__div = function(a, b) return a.x / b end
V.__mod = function(a, b) return a.x % b end
V.__idiv = function(a, b) return a.x // b end
V.__pow = function(a, b) return a.x ^ b end
V.__unm = function(a) return setmetatable({x = -a.x, y = -a.y}, V) end
V.__eq = function(a, b) return a.x == b.x and a.y == b.y end
V.__lt = function(a, b) return a.x < b.x end
V.__le = function(a, b) return a.x <= b.x end
V.__len = function(a) return 2 end
V.__concat = function(a, b) return tostring(a) .. "|" .. tostring(b) end
V.__tostring = function(a) return "(" .. a.x .. "," .. a.y .. ")" end
V.__call = function(self, k) return self.x * k end
V.__band = function(a, b) return "band" end
V.__shl = function(a, b) return "shl" end
V.__bnot = function(a) return "bnot" end
local function new(x, y) return setmetatable({x = x, y = y}, V) end
local a, b = new(1, 2), new(3, 4)
show(tostring(a + b), tostring(a - b), a * b, tostring(2 * a), a / 2, a % 2, a // 1, a ^ 2, tostring(-a))
show(a == b, a == new(1, 2), a ~= b, a < b, a <= b, a > b, a >= b, #a, a .. b, a .. "s", "s" .. a, 1 .. a)
show(a(10), a & b, a << 1, ~a, rawequal(a, new(1, 2)), rawlen(a))
-- __index chains and functions
local Base = {greet = function() return "base" end}
local Mid = setmetatable({mid = true}, {__index = Base})
local Leaf = setmetatable({}, {__index = Mid})
show(Leaf.greet(), Leaf.mid, Leaf.none, rawget(Leaf, "greet"))
local dyn = setmetatable({}, {__index = function(t, k) return k .. "!" end})
show(dyn.foo, dyn[1], rawget(dyn, "foo"))
-- __newindex
local log = {}
local prox = setmetatable({}, {__newindex = function(t, k, v) log[#log + 1] = k rawset(t, k, v) end})
prox.a = 1 prox.a = 2 prox.b = 3 show(table.concat(log, ","), prox.a, prox.b)
local store = {}
local redirect = setmetatable({}, {__newindex = store})
redirect.x = 5 show(rawget(redirect, "x"), store.x)
-- inheritance with super calls
local Animal = {} Animal.__index = Animal
function Animal.new(name) return setmetatable({name = name}, Animal) end
function Animal:speak() return self.name .. " makes a sound" end
local Dog = setmetatable({}, {__index = Animal}) Dog.__index = Dog
function Dog.new(name) local d = Animal.new(name) return setmetatable(d, Dog) end
function Dog:speak() return Animal.speak(self) .. " (woof)" end
show(Animal.new("cat"):speak(), Dog.new("rex"):speak(), getmetatable(Dog.new("a")) == Dog)
-- getmetatable / protected / strings
show(getmetatable("x").__index == string, getmetatable(1), type(getmetatable({})))
local prot = setmetatable({}, {__metatable = "locked"})
show(getmetatable(prot), pcall(setmetatable, prot, {}))
show(pcall(setmetatable, 1, {}), pcall(setmetatable, {}, 1), setmetatable({}, nil) ~= nil)
-- __tostring in print and tostring, __name
print(a, new(0, 0)) show(tostring(setmetatable({}, {__tostring = function() return "custom" end})))
show(pcall(tostring, setmetatable({}, {__tostring = function() return 1 end})), pcall(tostring, setmetatable({}, {__tostring = function() return {} end})))
-- __pairs
local pp = setmetatable({}, {__pairs = function(t) return function(_, k) if not k then return 1, "one" elseif k < 3 then return k + 1, "more" end end, t, nil end})
local seen = {} for k, v in pairs(pp) do seen[#seen + 1] = k .. v end show(table.concat(seen, ","))
-- comparison metamethods with mixed types, and errors
show(pcall(function() return a < 1 end), pcall(function() return {} < {} end), pcall(function() return a + 1 end))
show(pcall(function() return #nil end), pcall(function() return nil .. "x" end), pcall(function() return {} .. "x" end))
-- __eq only for same types, not called for rawequal tables with the same identity
local calls = 0 local E = {__eq = function() calls = calls + 1 return true end}
local e1, e2 = setmetatable({}, E), setmetatable({}, E) show(e1 == e2, e1 == e1, e1 ~= e2, calls)
-- __index on missing methods error message
show(pcall(function() local t = {} t:nomethod() end), pcall(function() local t = setmetatable({}, {__index = {}}) t.x.y = 1 end))
-- __call chains and varargs
local callable = setmetatable({}, {__call = function(self, ...) return select("#", ...), ... end})
show(callable(), callable(1, 2), pcall(callable, "a"))
-- __lt fallback for __le is not used in 5.4
local L = setmetatable({}, {__lt = function() return true end})
show(pcall(function() return L <= L end), L < L)
-- __concat with numbers and tables on either side
local C = setmetatable({}, {__concat = function(x, y) return (type(x) == "table" and "T" or x) .. (type(y) == "table" and "T" or y) end})
show(C .. 1, 1 .. C, C .. C, "a" .. "b" .. C, C .. "a" .. "b")
-- __len and # on strings/tables, __unm/__bnot on tables
show(#setmetatable({1, 2, 3}, {__len = function() return 42 end}), #"hello", #{1, 2})
-- rawset/rawget bypass
local R = setmetatable({}, {__newindex = function() error("no") end, __index = function() return "dflt" end})
rawset(R, "k", "v") show(R.k, R.other, rawget(R, "other"), pcall(function() R.z = 1 end))
-- tostring(nil) etc via __tostring absent, __name
show(tostring(setmetatable({}, {__name = "MyType"})):match("^MyType: ") ~= nil)
