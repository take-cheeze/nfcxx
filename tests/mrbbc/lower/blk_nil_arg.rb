def f
  yield
end
f { |a| a }
