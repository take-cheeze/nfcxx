class A
  def f(a, k: 1)
    yield a + k
  end
end
class B < A
  def f(a)
    super(a, k: 10) { |v| v * 2 }
  end
end
B.new.f(5)
