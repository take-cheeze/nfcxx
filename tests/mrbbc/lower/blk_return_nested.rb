def f
  yield
  5
end
def g
  f { f { return 7 } }
  8
end
g
