def fact(n)
  n < 2 ? 1 : n * fact(n - 1)
end
fact(10)
