def h(a, b = a + 1, c = b * 2)
  [a, b, c]
end
[h(1), h(1, 5), h(1, 5, 0)]
