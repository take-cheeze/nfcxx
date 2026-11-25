local last
for i = 1, 3 do
  local j = i * 10
  last = function() return j end
end
return last()
