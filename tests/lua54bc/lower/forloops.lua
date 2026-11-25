local s = 0
for i = 1, 10 do s = s + i end
for i = 10, 1, -3 do s = s + i * 100 end
for x = 0.5, 2.0, 0.5 do s = s + x * 1000 end
return s
