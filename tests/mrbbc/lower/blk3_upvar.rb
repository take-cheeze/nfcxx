def each_it
  yield
end
def m(a)
  each_it { each_it { each_it { a } } }
end
m(3)
