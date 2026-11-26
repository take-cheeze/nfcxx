-- error with a level: the message gets the position of the caller; the traceback starts at error
local function validate(x)
  if type(x) ~= "number" then
    error("expected a number", 2)
  end
  return x
end

local function use(v)
  local r = validate(v)
  return r
end

use("text")
