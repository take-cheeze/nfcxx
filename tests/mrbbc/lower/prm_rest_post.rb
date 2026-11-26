def f(a, *r, b)
  [a, r, b]
end
[f(1, 2), f(1, 2, 3), f(1, 2, 3, 4)]
