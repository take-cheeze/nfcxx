class A
  def m(a)
    a + 1
  end
end
class B < A
  def m(a)
    r = nil
    each_it { |x| r = super }
    r + x_of
  end
  def x_of
    0
  end
  def each_it
    yield 5
  end
end
B.new.m(1)
