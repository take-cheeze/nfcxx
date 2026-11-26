def f(a, *r)
  [a, r]
end
[f(1), f(1, 2), f(1, 2, 3)]
