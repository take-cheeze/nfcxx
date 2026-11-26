def inner
  yield 5
end
def outer
  inner { |v| v * 2 } + 1
end
outer
