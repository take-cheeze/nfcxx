class A
  def f(x)
    x + 100
  end
end
class B < A
  def f(x)
    [super(x), super(x + 1)]
  end
end
B.new.f(1)
