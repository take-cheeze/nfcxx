def m
  yield 3
end
t = 0
2.times { |i| t = t + i }
m { |v| t + v }
