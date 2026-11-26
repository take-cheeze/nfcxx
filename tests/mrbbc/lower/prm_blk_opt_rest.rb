def y1(v)
  yield v
end
[y1(5) { |a = 1, *b| [a, b] }, y1([]) { |a = 1, *b| [a, b] }, y1([8, 9]) { |a = 1, *b| [a, b] }]
