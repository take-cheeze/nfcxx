class A
  def f(a:)
    a
  end
end
class B < A
  def f
    super(a: 1)
  end
end
B.new.f
