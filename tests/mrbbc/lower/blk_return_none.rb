def f
  yield
  5
end
def g
  f { 1 }
  2
end
g
