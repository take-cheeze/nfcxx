class P
  def initialize(x, y = 7)
    @x = x
    @y = y
  end
  def sum(k = 0)
    @x + @y + k
  end
end
[P.new(1).sum, P.new(1, 2).sum(10)]
