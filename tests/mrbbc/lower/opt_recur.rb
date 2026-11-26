def fact(n, acc = 1)
  if n <= 1
    acc
  else
    fact(n - 1, acc * n)
  end
end
fact(5)
