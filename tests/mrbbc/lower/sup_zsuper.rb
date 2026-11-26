class A
  def f(x)
    x * 2
  end
  def g
    7
  end
end
class B < A
  def f(x)
    x = x + 1
    super
  end
  def g
    super + 1
  end
end
B.new.f(4) + B.new.g
