def f(*r, **k)
  [r, k]
end
[f, f(1, 2), f(1, z: 3), f(1, 2, z: 4, y: 5)]
