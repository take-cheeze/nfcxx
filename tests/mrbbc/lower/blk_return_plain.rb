def f
  yield
end
def g
  f { return 1 }
  2
end
g
