-- library functions in the traceback: "[C]: in function 'string.rep'", "[C]: in function 'error'"
local function check(s)
  return string.rep(s, 2)
end

local function go(v)
  local r = check(v)
  return r
end

go(nil)
