def f
  yield
  99
end
def g
  f { return 1 }
  2
end
g
