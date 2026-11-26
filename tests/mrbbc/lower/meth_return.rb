def sign(x)
  return -1 if x < 0
  return 1 if x > 0
  0
end
[sign(-5), sign(0), sign(7)]
