-- Method-style getters and small methods on objects with a metatable (the usual object pattern): obj:getx() and friends.
local Vec = {}
Vec.__index = Vec
function Vec.new(x, y) return setmetatable({x = x, y = y}, Vec) end
function Vec:getx() return self.x end
function Vec:gety() return self.y end
function Vec:dot(o) return self:getx() * o:getx() + self:gety() * o:gety() end
function Vec:len2() return self:dot(self) end
function Vec:setx(v) self.x = v end

local objs = {}
for i = 1, 16 do objs[i] = Vec.new(i, i + 1) end
local n = 3000000
local s = 0
for i = 1, n do
  local a, b = objs[i % 16 + 1], objs[(i * 7) % 16 + 1]
  s = s + a:getx() + b:gety() + a:dot(b) % 11
  a:setx(a:getx())
end
print(s, objs[3]:len2())
