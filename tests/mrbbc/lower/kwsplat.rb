def f(a: 1, **k)
  [a, k]
end
h = {a: 2, b: 3}
[f(**h), f(**h, c: 4), f(**{}), f(**{x: 9})]
