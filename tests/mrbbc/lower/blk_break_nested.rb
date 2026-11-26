def f
  yield 1
  9
end
r = 0
f { |a| r = f { |b| break a + b + 100 } }
r
