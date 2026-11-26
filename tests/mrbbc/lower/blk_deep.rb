def f
  yield 1
end
x = 1
f { |a| f { |b| b + a + x } }
