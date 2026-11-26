class Pt
  def initialize(x, y)
    @x = x
    @y = y
  end

  def sum
    @x + @y
  end

  def add(o)
    Pt.new(@x + o.sum, @y)
  end
end
Pt.new(1, 2).add(Pt.new(10, 20)).sum
