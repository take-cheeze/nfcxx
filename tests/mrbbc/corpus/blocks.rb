def twice(x)
  yield(x) + yield(x + 1)
end
acc = 0
r = twice(3) { |v| acc += v; v * 2 }
l = lambda { |k| k + acc }
l.call(r)
