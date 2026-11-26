class C
  def initialize(a, k: 1)
    @a = a
    @k = k
  end

  def sum
    @a + @k
  end
end
[C.new(1).sum, C.new(1, k: 5).sum]
