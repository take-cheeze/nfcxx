i = 0
t = 0
while i < 200000
  a = [i, i + 1, i + 2]
  b = a + [i]
  t = t + b[1] + b.size
  i += 1
end
t
