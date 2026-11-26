class Two
  def one
    yield 1
  end
end
class B
  def f
    Two.new.one { |k| super(k) }
  end
end
B.new.f
