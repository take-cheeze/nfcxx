class P
  def initialize(x)
    @x = x
    @s = "p#{x}"
  end

  def x
    @x
  end
end
i = 0
t = 0
while i < 200000
  t = t + P.new(i).x
  i += 1
end
t
