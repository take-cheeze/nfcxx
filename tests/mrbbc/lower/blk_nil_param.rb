def f(a, &nil)
  a + 1
end
def g(&nil)
  3
end
[f(1), f(2), g, g(&nil)]
