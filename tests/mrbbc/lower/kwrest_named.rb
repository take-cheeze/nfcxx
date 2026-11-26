def f(a, k: 1, **r)
  [a, k, r]
end
[f(1), f(1, k: 2), f(1, z: 3, k: 4, y: 5)]
