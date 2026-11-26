class A
  def m(a)
    if block_given?
      yield + a
    else
      100 + a
    end
  end
end
class B < A
  def m(a)
    r = nil
    each_it { each_it { r = super(a) } }
    r
  end
  def each_it
    yield
  end
end
B.new.m(1) { 4 }
