class V
  def initialize(x)
    @x = x
  end

  def to_s
    "v#{@x}"
  end
end
V.new(3).to_s
