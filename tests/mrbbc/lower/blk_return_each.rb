def f
  yield 1
  yield 2
  3
end
def g
  f { |v| return v * 10 if v == 2; v }
end
g
