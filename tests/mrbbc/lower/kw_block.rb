def f(a, k: 1)
  yield a + k
end
f(1, k: 2) { |v| v * 10 }
