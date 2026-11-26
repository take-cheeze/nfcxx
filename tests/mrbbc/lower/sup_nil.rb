class A
  def initialize
    @x = 1
  end
end
class B < A
  def initialize
    @r = super()
  end
  def r
    @r
  end
end
class C < Object
  def hi
    5
  end
end
[B.new.r, C.new.hi]
