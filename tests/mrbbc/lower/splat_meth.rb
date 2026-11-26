def m(a, b = 5, c = 6)
  [a, b, c]
end
x = [1, 2]
[m(*x), m(*[7]), m(*x, *[9])]
