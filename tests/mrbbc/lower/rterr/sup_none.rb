class A
end
class B < A
  def f
    super
  end
end
B.new.f
