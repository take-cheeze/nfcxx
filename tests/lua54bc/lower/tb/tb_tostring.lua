-- an error object whose __tostring gives the message: lua.c prints that text and no traceback
local err = setmetatable({}, {__tostring = function() return "custom failure" end})
local function fail()
  error(err)
end
fail()
