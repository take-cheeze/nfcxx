class C
  def initialize(a, k: 1)
    @v = a + k
  end

  def v
    @v
  end
end
h = {k: 5}
[C.new(1, **h).v, C.new(2, **{}).v]
