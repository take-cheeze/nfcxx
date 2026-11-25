local s = 7
for i = 5, 1 do s = s + 1000 end
for i = 1, 0.5 do s = s + 1000 end
for i = 3, 3 do s = s + i end
for x = 1.0, 0.0, -0.25 do s = s + x end
return s
