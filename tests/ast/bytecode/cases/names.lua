-- Error messages name the variables they are about, as Lua's debug information lets them: a local, a global, a field, an upvalue,
-- a method, a constant string. Each message is printed without its position.
local function try(f, ...)
  local ok, e = pcall(f, ...)
  print(ok, (tostring(e):gsub("^.-:%d+: ", "")))
end
local t = {}
local up
try(function() return t.a.b end)
try(function() return nothere.x end)
try(function() return up.x end)
try(function() local l; return l.x end)
try(function() return t:nomethod() end)
try(function() return -{} end)
try(function() return {} .. "x" end)
try(function() local s = nil; return s .. "x" end)
try(function() return t.x.y.z end)
try(function() return 1 < "x" end)
try(function() return {} < {} end)
try(function() return math.floor("x") end)
try(function() return ("x"):rep({}) end)
try(function() undefined_fn() end)
try(function() t.field() end)
try(function() local q = 5; q() end)
try(function() local n = 1.5; return n | 1 end)
try(function() return #up end)
try(function() for i = 1, "x" do end end)
