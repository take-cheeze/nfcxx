class A
  def initialize(v)
    @v = v
  end
  def val
    @v
  end
end
class B < A
  def initialize(x)
    super(x * 2)
    @w = 1
  end
  def w
    @w
  end
end
class C < A
end
b = B.new(3)
[b.val, b.w, C.new(4).val]
