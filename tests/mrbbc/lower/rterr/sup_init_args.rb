class A
end
class B < A
  def initialize(x)
    super
  end
end
B.new(1)
