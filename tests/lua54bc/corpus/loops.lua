local t = 0
for i = 1, 10, 2 do t = t + i end
for k, v in pairs({ "a", "b" }) do t = t + #v end
local n = 0
while n < 5 do n = n + 1 if n == 3 then goto skip end ::skip:: end
repeat n = n - 1 until n <= 0
return t, n
