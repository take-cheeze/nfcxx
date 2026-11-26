class A
end
class B < A
  def m(a)
    each_it { super }
  end
  def each_it
    yield
  end
end
B.new.m(1)
