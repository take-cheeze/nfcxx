local keep = {}
local total = 0
for i = 1, 200000 do
  local t = {i, "s" .. i}
  total = total + t[1] + #t[2]
  if i % 5000 == 0 then keep[#keep + 1] = t end
end
collectgarbage()
local n = 0
for _, v in ipairs(keep) do n = n + v[1] end
return total, #keep, n, collectgarbage("count") < 100000
