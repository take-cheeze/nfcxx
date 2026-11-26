def y1
  yield 1
end
y1 { |a = 1, *b| a }
