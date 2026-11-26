class A
  def f(x)
    x
  end
end
class B < A
  def f(x)
    a = [x]
    super(*a)
  end
end
B.new.f(1)
