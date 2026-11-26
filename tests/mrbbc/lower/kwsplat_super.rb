class A
  def m(a, k: 1)
    a + k
  end
end
class B < A
  def m(a, k: 2)
    super(a, **{k: 10})
  end
end
B.new.m(1)
