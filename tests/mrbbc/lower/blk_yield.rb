def twice
  yield 1
  yield 2
end
x = 10
twice { |v| x + v }
