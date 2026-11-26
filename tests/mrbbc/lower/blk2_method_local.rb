def each_it
  yield
end
def m
  x = 1
  each_it { each_it { x = x + 1 } }
  x
end
m
