def twice(v)
  yield v
  yield v + 1
end
i = 0
t = 0
while i < 100000
  twice(i) { |x| t = t + [x].size + x }
  i += 1
end
t
