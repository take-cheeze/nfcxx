def f
  yield
end
x = 5
f do
  x = 7
end
x
