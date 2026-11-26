class A
  def f(x)
    x
  end
end
class B < A
  def f
    super(1, 2)
  end
end
B.new.f
