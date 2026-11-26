def f
  yield
  5
end
def g
  r = f { break 7 }
  r + 1
end
g
