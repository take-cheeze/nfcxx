def sum_to(n)
  s = 0
  i = 1
  while i <= n
    s = s + i
    i = i + 1
  end
  s
end
sum_to(10) + sum_to(3)
