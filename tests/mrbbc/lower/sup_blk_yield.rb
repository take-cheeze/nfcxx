class A
  def h(x)
    yield(x) + 100
  end
end
class Two
  def one
    yield 7
  end
end
class B < A
  def h(x)
    out = nil
    super(x + 1) { |v| out = v * 2 }
    Two.new.one { |k| out = out + super(k) { |w| w } }
    out
  end
end
B.new.h(1)
