-- tail calls: the frame that made the call is gone, and the callee is followed by "(...tail calls...)"
local function a(n)
  if n == 0 then
    return nil + 1
  end
  return a(n - 1)
end

local function b()
  return a(3)
end

local function c()
  local x = b()
  return x
end

print(c())
