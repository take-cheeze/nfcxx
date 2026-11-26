def y1(v)
  yield v
end
[y1([1, 2, 3]) { |a, *r, b| [a, r, b] }, y1(4) { |a, *r, b| [a, r, b] }]
