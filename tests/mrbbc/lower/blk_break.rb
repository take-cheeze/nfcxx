def each_two
  yield 1
  yield 2
  3
end
each_two { |v| break v * 10 if v == 2; v }
