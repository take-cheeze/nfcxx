class A
  def f(x)
    if block_given?
      1
    else
      x * 3
    end
  end
end
class Two
  def each_two
    yield 1
    yield 2
  end
end
class B < A
  def f(x)
    r = nil
    Two.new.each_two { |i| r = super(i + x) }
    r
  end
end
B.new.f(5) { |v| v }
