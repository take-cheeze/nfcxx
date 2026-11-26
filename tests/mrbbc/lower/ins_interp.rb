class V
  def initialize(x)
    @x = x
  end

  def to_s
    "v#{@x}"
  end
end
x = V.new(4)
"a#{x}b#{V.new(5)}c"
