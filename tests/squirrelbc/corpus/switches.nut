// A switch with cases and a default, and a while loop with break and continue.
local x = 3
local r = 0
switch (x) {
  case 1: r = 10; break
  case 3: r = 30; break
  default: r = -1
}
local i = 0
while (true) {
  i = i + 1
  if (i < 5) continue
  break
}
return r + i
