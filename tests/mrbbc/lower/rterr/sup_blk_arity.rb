class Two
  def one
    yield 1
  end
end
class A
  def f(x)
    x
  end
end
class B < A
  def f
    Two.new.one { |k| super(1, 2) }
  end
end
B.new.f
