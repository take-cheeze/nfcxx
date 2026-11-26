def m
  yield 1
end
m { |a, b| b }
