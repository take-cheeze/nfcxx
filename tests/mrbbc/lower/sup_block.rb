class A
  def f
    yield + 1
  end
end
class B < A
  def f
    super { 7 }
  end
end
class C < A
  def f
    super
  end
end
[B.new.f, C.new.f { 10 }]
