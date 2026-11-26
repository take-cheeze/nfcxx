class Pt
  attr_accessor :x, :y
  def initialize(x, y = 2)
    @x = x
    @y = y
  end
  def sum; @x + @y; end
end
p1 = Pt.new(1)
p1.x = 40
p1.sum
