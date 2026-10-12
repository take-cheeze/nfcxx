-- Method calls obj:name(args) on tables: getters and setters, methods inherited through __index chains, methods that call other
-- methods of self, methods returning self for chaining, receivers of different classes at one site, fields that hold functions,
-- errors with the method's name, and a receiver that stops being a table.
local Point = {}
Point.__index = Point
function Point.new(x, y) return setmetatable({x = x, y = y}, Point) end
function Point:getx() return self.x end
function Point:gety() return self.y end
function Point:setx(v) self.x = v end
function Point:dot(o) return self.x * o.x + self.y * o.y end
function Point:len2() return self:dot(self) end
function Point:add(o) return Point.new(self.x + o.x, self.y + o.y) end
function Point:scale(k) self.x = self.x * k; self.y = self.y * k; return self end
function Point:str() return "(" .. self.x .. "," .. self.y .. ")" end
function Point:swap() self.x, self.y = self.y, self.x end
function Point:kind() return "point" end

print("-- getters, setters, methods that call methods")
local p, q = Point.new(1, 2), Point.new(3, 4)
for i = 1, 8 do
  p:setx(i)
  print(p:getx(), p:gety(), q:getx() + q:gety(), p:dot(q), p:len2(), p:add(q):str(), p:kind())
end

print("-- chaining and mutation through self")
local r = Point.new(1, 1)
for i = 1, 6 do
  r:scale(2):scale(1):scale(1)
  print(r:str(), r:len2(), r:add(r):str())
  r:swap()
end

print("-- inheritance: the method is two tables away")
local Point3 = setmetatable({}, {__index = Point})
Point3.__index = Point3
function Point3.new(x, y, z) local o = Point.new(x, y); o.z = z; return setmetatable(o, Point3) end
function Point3:getz() return self.z end
function Point3:kind() return "point3 over " .. Point.kind(self) end
function Point3:len2() return Point.len2(self) + self.z * self.z end
local t = Point3.new(1, 2, 3)
for i = 1, 6 do
  t:setx(i)
  print(t:getx(), t:getz(), t:len2(), t:kind(), t:dot(t), t:str())
end

print("-- one site, receivers of different classes")
local Dog = {}; Dog.__index = Dog
function Dog:speak() return "woof " .. self.n end
function Dog:legs() return 4 end
local Bird = {}; Bird.__index = Bird
function Bird:speak() return "tweet " .. self.n end
function Bird:legs() return 2 end
local Fish = {n = "f", speak = function(self) return "..." end}
Fish.__index = Fish
local animals = {setmetatable({n = 1}, Dog), setmetatable({n = 2}, Bird), setmetatable({n = 3}, Dog), setmetatable({n = 4}, Fish)}
for round = 1, 3 do
  local out, legs = {}, 0
  for i, a in ipairs(animals) do
    out[#out + 1] = a:speak()
    legs = legs + (a.legs and a:legs() or 0)
  end
  print(table.concat(out, ";"), legs)
end

print("-- fields that hold functions, called as methods")
local obj = {n = 0}
obj.bump = function(self, k) self.n = self.n + k; return self.n end
obj.get = function(self) return self.n end
for i = 1, 6 do print(obj:bump(i), obj:get(), obj.get(obj), obj.bump(obj, 0)) end

print("-- errors inside methods, and calling a method that is not there")
local function try(f, ...) print(pcall(f, ...)) end
local bad = Point.new(1, nil)
function Point:boom() return self.nope.x end
function Point:level2() error("level2 from " .. self.x, 2) end
for i = 1, 6 do
  try(function() return bad:dot(p) end)
  try(function() return p:boom() end)
  try(function() p:level2() end)           -- not a tail call (the engine runs tail calls as calls)
  try(function() return p:missing() end)
  try(function() return (nil):getx() end)
  try(function() local n = nil; return n:getx() end)
  try(function() return p:getx(1, 2, 3) end)
end

print("-- the receiver stops being a table")
local function getx(o) return o:getx() end
local things = {p, q, Point3.new(7, 8, 9), "string", 12, setmetatable({}, {__index = function(_, k) return function() return "dyn " .. k end end})}
for round = 1, 3 do
  for i, o in ipairs(things) do
    print(i, pcall(getx, o))
  end
end

print("-- string methods through the same syntax")
local function shout(s) return s:upper() .. "!" end
for i = 1, 5 do print(shout("a" .. i), ("x"):rep(i), (i .. ""):len()) end

print("-- methods that return nothing, one value, many")
local M = {}
function M:none() end
function M:one() return 1 end
function M:many() return 1, 2, 3 end
for i = 1, 5 do
  print(select('#', M:none()), select('#', M:one()), select('#', M:many()), (M:many()), M:many())
  local a, b, c, d = M:many()
  print(a, b, c, d, #{M:many()}, #{M:none()})
end

print("-- one method function, a different closure (other upvalues) in each object")
local function mkobj(n, step)
  local calls = 0
  return {n = n, get = function(self) calls = calls + 1; return n + self.n + calls * step end, count = function() return calls end}
end
local objs = {mkobj(1, 10), mkobj(100, 1000), mkobj(-5, 0)}
for round = 1, 5 do
  local out = {}
  for i, o in ipairs(objs) do out[#out + 1] = o:get() .. "/" .. o:count() end
  print(table.concat(out, " "))
end
