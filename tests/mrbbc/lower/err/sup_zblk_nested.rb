class A
  def m(a)
    a
  end
end
class B < A
  def m(a)
    r = nil
    each_it { each_it { r = super } }
    r
  end
  def each_it
    yield
  end
end
B.new.m(1)
