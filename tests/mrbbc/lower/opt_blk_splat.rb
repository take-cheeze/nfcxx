def y1(v)
  yield v
end
[y1([1, 2]) { |a, b = 5| [a, b] }, y1([7]) { |a, b = 5| [a, b] }, y1([]) { |a, b = 5| [a, b] }, y1(4) { |a, b = 5| [a, b] }]
