def y2
  yield 1
  yield 2, 3
end
out = []
y2 { |x, z = 9| out = out + [x + z] }
out
