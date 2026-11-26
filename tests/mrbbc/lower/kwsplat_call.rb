def g(x, k: 1)
  [x, k]
end
h = {k: 5}
e = {}
[g(1, **h), g(2, **e), g(3, **e, k: 9)]
