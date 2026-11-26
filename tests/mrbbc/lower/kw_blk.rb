def y1
  yield 4
end
y1 { |a, k: 2| [a, k] }
