class A
  def val(x)
    x + 1
  end
  def name
    "a"
  end
  def hi
    name + "!"
  end
end
class B < A
  def val(x)
    super(x) * 10
  end
  def name
    "b"
  end
end
class C < B
  def val(x)
    super + 5
  end
end
[C.new.val(2), B.new.hi, C.new.hi]
