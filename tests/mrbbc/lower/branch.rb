x = nil
y = x || 5
z = false || 7
w = 3 && 4
v = nil && 2
if w > 3 then r = 10 else r = 20 end
unless v then r = r + 1 end
r + y + z
