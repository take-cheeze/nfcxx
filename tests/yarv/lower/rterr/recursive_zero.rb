def depth(n)
  n < 1 ? 1 / n : depth(n - 1)
end
depth(3)
