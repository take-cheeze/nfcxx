def m(a)
  yield a + 1
end
m(2) { |v| v * 10 }
