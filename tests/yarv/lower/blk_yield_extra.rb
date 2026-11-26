def m
  yield 1, 2, 3
end
m { |a| a }
