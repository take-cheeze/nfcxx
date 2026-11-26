def f(a = 1, k: 2)
  [a, k]
end
[f(3), f(3, k: 4), f, f(k: 5)]
