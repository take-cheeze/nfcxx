def inner
  yield 1
  2
end
def outer
  inner { |v| return v + 40 }
  3
end
outer
