local function show(...) print(...) end
-- counters and shared upvalues
local function counter()
  local n = 0
  return function() n = n + 1 return n end, function() return n end
end
local inc, get = counter()
inc(); inc(); inc()
show(get(), inc(), get())
-- a fresh local per loop iteration
local fs = {}
for i = 1, 5 do fs[#fs + 1] = function() return i end end
show(fs[1](), fs[3](), fs[5]())
local gs = {}
for _, v in ipairs({"a", "b", "c"}) do gs[#gs + 1] = function() return v end end
show(gs[1](), gs[2](), gs[3]())
local hs = {}
local j = 0
while j < 3 do j = j + 1 local k = j * 10 hs[j] = function() k = k + 1 return k end end
show(hs[1](), hs[1](), hs[2](), hs[3]())
local ws = {}
local c = 0
repeat local x = c ws[#ws + 1] = function() return x end c = c + 1 until x >= 2
show(#ws, ws[1](), ws[3]())
-- recursion
local function fact(n) if n <= 1 then return 1 end return n * fact(n - 1) end
show(fact(10), fact(20), fact(25) == fact(25))
local fib; fib = function(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
show(fib(15))
local function even(n) if n == 0 then return true end return odd(n - 1) end
function odd(n) if n == 0 then return false end return even(n - 1) end
show(pcall(even, 4))
-- multiple returns and varargs
local function mr() return 1, 2, 3 end
local function none() end
show(mr()); show((mr())); show(mr(), mr()); show(({mr()})[3], #{mr(), mr()}, #{mr(), (mr())})
local a, b, c, d = mr() show(a, b, c, d)
local x, y = none() show(x, y)
local function va(...) return select("#", ...), ... end
show(va()); show(va(nil)); show(va(1, nil, nil)); show((va(1, 2)))
local function pass(...) return ... end
show(pass(1, 2, 3), pass(), pass(4, 5))
local function sum(...) local s = 0 for _, v in ipairs({...}) do s = s + v end return s end
show(sum(), sum(1), sum(1, 2, 3, 4, 5))
local function tail(...) local t = {...} return #t, ... end
show(tail(1, 2, 3))
show(select(2, "a", "b", "c"), select(-1, "a", "b", "c"), select("#"), select("#", nil, nil))
show(pcall(select, 0), pcall(select, -5, 1))
local function named(a, b, ...) return a, b, select("#", ...) end
show(named(1), named(1, 2, 3, 4), named())
-- table.unpack and packing round trip
show(table.unpack({1, 2, 3})); show(pass(table.unpack({1, 2, 3}, 2)))
-- methods and self
local obj = {n = 0}
function obj:add(k) self.n = self.n + k return self end
function obj.static(k) return k * 2 end
show(obj:add(1):add(2):add(3).n, obj.static(4), obj.add(obj, 10).n)
local Account = {} Account.__index = Account
function Account.new(b) return setmetatable({balance = b}, Account) end
function Account:deposit(v) self.balance = self.balance + v end
function Account:get() return self.balance end
local acc = Account.new(100) acc:deposit(50) show(acc:get(), acc.balance, Account.get(acc))
-- upvalues shared between closures created in the same scope
local function pair() local v = 0 return function() v = v + 1 return v end, function() v = v * 2 return v end end
local p1, p2 = pair() show(p1(), p2(), p1(), p2())
-- nested closures three deep
local function l1() local a = 1 return function() local b = 2 return function() a = a + 1 b = b + 1 return a + b end end end
local f3 = l1()() show(f3(), f3())
-- closures capturing parameters and loop variables with modification
local function mk(x) return function(d) x = x + d return x end end
local m = mk(10) show(m(1), m(2), mk(0)(5))
for i = 1, 3 do local f = function() i = i + 10 return i end show(f(), i) end
-- string method closure, immediate call, long call chains
show((function(...) return select("#", ...) end)(1, 2, 3), (function() return "iife" end)())
show(#(function() return {1, 2, 3} end)(), ("x"):rep(3):upper():lower())
-- global functions defined in nested scope
do local function inner() return "inner" end function gfun() return inner() .. "!" end end show(gfun())
-- varargs in the main chunk
show(select("#", ...))
-- goto-free continue idiom and early return from nested loops
local function find(t, x) for i = 1, #t do for j = 1, #t[i] do if t[i][j] == x then return i, j end end end return nil end
show(find({{1, 2}, {3, 4}}, 4), find({{1}}, 9))
