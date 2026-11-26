def f
  yield 1
end
f { |x| x }
