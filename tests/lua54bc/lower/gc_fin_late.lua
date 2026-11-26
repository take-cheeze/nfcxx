-- Only a table whose metatable has __gc when setmetatable is called is marked for finalization.
local mt = {}
local early = setmetatable({}, mt)
mt.__gc = function() print("early: should not run") end
local late = setmetatable({}, {__gc = function() print("late gc") end})
late = nil
collectgarbage()
print("end", early ~= nil)
