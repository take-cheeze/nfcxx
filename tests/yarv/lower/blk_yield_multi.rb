def m
  yield 1, 2
end
m { |a, b| b * 10 + a }
