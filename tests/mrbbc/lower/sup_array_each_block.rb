class A
  def f
    1
  end
end
class B < A
  def f
    [1].each { super }
  end
end
B.new.f
