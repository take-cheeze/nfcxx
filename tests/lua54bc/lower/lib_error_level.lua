local function check(x)
  if type(x) ~= "number" then
    error("expected number", 2)
  end
  return x
end
local function caller()
  local v = check("oops")
  return v
end
print(pcall(caller))
print(pcall(check, "x"))
local function lvl3() error("deep", 3) end
local function mid() lvl3() end
local function top()
  mid()
end
print(pcall(top))
print(pcall(error, "plain", 2))
print(pcall(function() error("here") end))
print(pcall(function() error("lvl0", 0) end))
print(pcall(function() error({code = 1}, 2) end) == false)
print(select(2, pcall(function() error("a", 1) end)))
print(xpcall(function() error("boom") end, function(m) return "handled: " .. m end))
print(xpcall(function(a, b) return a + b end, print, 3, 4))
print(xpcall(function() return 1, 2 end, print))
print(xpcall(error, function(m) return "H:" .. tostring(m) end, "x", 0))
return "done"
