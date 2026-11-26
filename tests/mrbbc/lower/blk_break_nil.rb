def f
  yield
  5
end
x = f { break }
x
