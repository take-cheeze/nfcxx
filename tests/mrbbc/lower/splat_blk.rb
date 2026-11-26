def y1(a)
  yield a
end
x = [5]
y1(*x) { |v| v + 1 }
