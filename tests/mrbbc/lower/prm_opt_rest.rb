def f(a = 7, *r)
  [a, r]
end
[f, f(1), f(1, 2, 3)]
