def walk(n)
  if n > 0
    yield n
    walk(n - 1) { |z| z }
  else
    0
  end
end
s = 0
walk(3) { |q| s = s + q }
s
