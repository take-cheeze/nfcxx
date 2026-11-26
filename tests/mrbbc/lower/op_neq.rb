class P
  def initialize(v)
    @v = v
  end

  def v
    @v
  end

  def ==(o)
    @v == o.v
  end
end
[P.new(1) != P.new(1), P.new(1) != P.new(2)]
