-- __gc finalizers run on collectgarbage("collect") for the objects that became unreachable, newest first.
local mt = {__gc = function(o) print("gc", o.name) end}
local function new(name) return setmetatable({name = name}, mt) end
do
  local a = new("a")
  local b = new("b")
  local c = new("c")
end
collectgarbage()
print("after collect")
local keep = new("keep")
collectgarbage()
print("kept", keep.name)
return "done"
