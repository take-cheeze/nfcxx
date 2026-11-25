local function outer()
  local x = 10
  return function()
    return function() x = x + 1 return x end
  end
end
local mid = outer()
local inner = mid()
inner()
return inner()
