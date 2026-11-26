def sq(n)
  n * n
end
def f
  yield 3
end
f { |v| sq(v) + 1 }
