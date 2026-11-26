def y3
  yield 1, 2, 3
end
y3 { |a, b = 2| [a, b] }
