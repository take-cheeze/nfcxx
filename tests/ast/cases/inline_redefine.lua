-- A call site that the engine has rewritten for one function must notice when the callee is another function afterwards: a global
-- or a field that is assigned again, a native, a table with __call, nil, a closure of the same function with other upvalues, a
-- method that is replaced in the class or shadowed in the instance.
local function try(f, ...)
  local r = table.pack(pcall(f, ...))
  for i = 1, r.n do r[i] = tostring(r[i]) end
  print(table.concat(r, " "))
end

print("-- a global function assigned again")
function g(x) return x + 1 end
local function use()
  local s = 0
  for i = 1, 10 do s = s + g(i) end
  return s
end
print(use(), use(), use())
g = function(x) return x * 2 end            -- another function of the same shape
print(use(), use())
g = function(x) return x - 1, "extra" end   -- another one that returns two values
print(use())
g = math.abs                                -- a native
print(use(), use())
g = setmetatable({}, {__call = function(self, x) return -x end})
print(use(), use())
g = nil
try(use)
g = function(x) return x end
print(use(), use())
function g(x) return x + 1 end              -- the first shape again, a new closure
print(use(), use())

print("-- the same function, closures with different upvalues")
local function make(k, name) return function(x) return x + k end end
local adders = {make(1), make(10), make(100), make(-5)}
local function run(f)
  local s = 0
  for i = 1, 5 do s = s + f(i) end
  return s
end
for round = 1, 3 do
  for i, f in ipairs(adders) do print(round, i, run(f)) end
end

print("-- a call through a table field")
local lib = {}
function lib.f(x) return x * 3 end
local function uselib()
  local s = 0
  for i = 1, 6 do s = s + lib.f(i) end
  return s
end
print(uselib(), uselib(), uselib())
function lib.f(x) return x * 5 end
print(uselib(), uselib())
lib.f = nil
try(uselib)
lib.f = string.len
try(uselib)
lib.f = tostring
print(uselib == nil, pcall(uselib))

print("-- the argument count at the site and the callee's parameters change together")
local function two(a, b) return (a or 0) * 10 + (b or 0) end
local h = two
local function callh()
  local out = {}
  for i = 1, 5 do out[#out + 1] = h(i, i + 1) end
  return table.concat(out, ",")
end
print(callh(), callh(), callh())
h = function(a) return a end
print(callh())
h = function(a, b, c) return c end
print(callh())

print("-- methods: replaced in the class, shadowed by the instance, removed")
local C = {}
C.__index = C
function C:get() return self.v end
local o = setmetatable({v = 5}, C)
local function sumget(obj)
  local s = 0
  for i = 1, 5 do s = s + obj:get() end
  return s
end
print(sumget(o), sumget(o), sumget(o))
function C:get() return self.v * 2 end
print(sumget(o))
o.get = function(self) return -1 end
print(sumget(o))
o.get = nil
print(sumget(o))
local o2 = setmetatable({v = 1}, {__index = {get = function(self) return 100 + self.v end}})
print(sumget(o2))
print(sumget(o), sumget(o2), sumget(o))
C.get = nil
try(sumget, o)
C.get = 3
try(sumget, o)
C.get = setmetatable({}, {__call = function(self, obj) return obj.v end})
print(sumget(o))
function C.get(self) return self.v + 1 end
print(sumget(o))

print("-- a function replaced while it runs")
local function selfmod(n)
  if n == 0 then return 0 end
  return 1 + g(n - 1)
end
g = selfmod
print(selfmod(5), selfmod(5))
g = function(n) return 100 end
print(selfmod(5), selfmod(5))
