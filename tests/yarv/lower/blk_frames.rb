def f(n)
  t = n * 10
  n.times { |i| t = t + 1 }
  t
end
f(2) + f(3)
