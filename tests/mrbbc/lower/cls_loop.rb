class Counter
  def initialize
    @n = 0
  end

  def bump
    @n = @n + 1
  end

  def n
    @n
  end
end
c = Counter.new
i = 0
while i < 5
  c.bump
  i += 1
end
c.n
