def count(n)
  i = 0
  while i < n
    yield i
    i = i + 1
  end
  n
end
s = 0
count(4) { |k| s = s + k }
s
