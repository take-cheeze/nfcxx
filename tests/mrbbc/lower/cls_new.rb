class Foo
  def initialize(x)
    @x = x
  end

  def get
    @x
  end
end
Foo.new(3).get
