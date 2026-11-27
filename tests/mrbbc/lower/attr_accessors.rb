class Point
  attr_reader :x
  attr_accessor :y, :label
  attr_writer :z
  def initialize(x)
    @x = x
    @y = x * 2
  end
  def z_value
    @z
  end
  def bump
    @y = y + 1
    y
  end
end
class Point3 < Point
  attr_accessor :w
end
p1 = Point.new(3)
p1.label = "a"
p1.z = [1, p1.x]
q = Point3.new(5)
q.w = q.bump
[p1.x, p1.y, p1.label, p1.z_value, q.w, q.y, q.label, (p1.y = 7), p1.y]
