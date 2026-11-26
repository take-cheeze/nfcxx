def m(a)
  yield(*a)
end
m(1) { |v| v }
