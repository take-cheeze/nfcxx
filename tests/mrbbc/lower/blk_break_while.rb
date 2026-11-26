def f
  i = 0
  while i < 3
    yield i
    i += 1
  end
  99
end
f { |v| break v + 40 if v == 1 }
