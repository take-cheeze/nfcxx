def each3
  i = 0
  while i < 3
    yield i
    i += 1
  end
  i
end
s = 0
each3 { |v| s += v }
s
