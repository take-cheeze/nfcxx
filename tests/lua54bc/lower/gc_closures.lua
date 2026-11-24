local fs = {}
for i = 1, 30000 do
  local v = i * 2
  local f = function(x) v = v + x return v end
  f(1)
  if i % 3000 == 0 then fs[#fs + 1] = f end
end
collectgarbage()
local r = 0
for _, f in ipairs(fs) do r = r + f(0) end
return r, #fs
