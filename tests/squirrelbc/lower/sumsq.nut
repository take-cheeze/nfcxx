local i = 0
local s = 0
do {
  s = s + i * i
  i = i + 1
} while (i < 1000)
return s
