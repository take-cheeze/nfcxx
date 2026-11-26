def f
  yield 1, 2
end
f { |a| a }
