class Outer
  class Inner
    def v
      4
    end
  end

  def make
    Inner.new.v * 2
  end
end
Outer.new.make
