def f
  yield
end
x = 1
f { |a| f { |b| b + a + x } }
