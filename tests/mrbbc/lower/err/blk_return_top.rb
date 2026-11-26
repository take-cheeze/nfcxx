def f
  yield
  5
end
f { return 1 }
