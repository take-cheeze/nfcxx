def inner
  yield 4
end
def outer
  inner { |v| yield v + 1 }
end
outer { |w| w * 10 }
