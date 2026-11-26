def f(a, b = nil)
  [a, b]
end
def g(a = false)
  a
end
[f(1), f(1, 2), g, g(true)]
