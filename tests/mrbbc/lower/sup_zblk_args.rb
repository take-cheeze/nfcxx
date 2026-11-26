class A
  def m(a, b)
    [a, b]
  end
end
class B < A
  def m(a, b)
    r = nil
    each_it { r = super }
    r
  end
  def each_it
    yield
  end
end
B.new.m(1, 2)
