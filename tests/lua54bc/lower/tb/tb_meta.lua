-- metamethods in the traceback: "in metamethod 'index'" for the function that handles the event
local mt = {}
mt.__index = function(t, k) error("no field " .. k) end
local obj = setmetatable({}, mt)

local function read()
  local v = obj.name
  return v
end

read()
