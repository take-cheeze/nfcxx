def y2
  yield 1, 2, 3
end
out = []
y2 { |a, *r| out = out + [[a, r]] }
out
