def find(n)
  i = 0
  while true
    return i if i * i > n
    i = i + 1
  end
end
find(50)
