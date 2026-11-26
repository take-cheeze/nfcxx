def each_it
  yield
end
t = 5
each_it { each_it { t = t + 1 } }
t
