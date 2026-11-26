def g
  yield [1, 2]
end
def h
  yield
end
g { |a, b, c| [a, b, c] }
