def f(*r, k: 3)
  [r, k]
end
[f, f(1, 2), f(1, k: 4), f(1, 2, k: 5)]
