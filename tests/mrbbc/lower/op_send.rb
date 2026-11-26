class V
  def initialize(x)
    @x = x
  end

  def x
    @x
  end

  def +(o)
    V.new(@x + o.x)
  end

  def ==(o)
    @x == o.x
  end
end
[V.new(1).+(V.new(2)).x, V.new(4).==(V.new(4)), V.new(4).==(V.new(5))]
