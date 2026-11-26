def y0
  yield
end
def y1(v)
  yield v
end
[y0 { |x = 9| x }, y1(4) { |x = 9| x }, y1(1) { |x, y = 2, z = 3| [x, y, z] }]
