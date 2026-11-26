class A
  def m
    3
  end
end
class B < A
  def m
    r = nil
    each_it { r = super }
    r
  end
  def each_it
    yield
  end
end
B.new.m
