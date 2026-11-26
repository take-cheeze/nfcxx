class A
  def m(a, b = 2)
    [a, b]
  end
end
class B < A
  def m(a, b = 3)
    super
  end
end
B.new.m(1)
