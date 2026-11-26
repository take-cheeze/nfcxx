class A
  def g(x)
    x + 1
  end
end
class Two
  def sum2
    a = yield 1
    b = yield 2
    a + b
  end
end
class B < A
  def g(x)
    Two.new.sum2 { |i| Two.new.sum2 { |j| super(j + 6) { |z| z } } }
  end
end
class C < B
  def g(x)
    super(x)
  end
end
C.new.g(0)
