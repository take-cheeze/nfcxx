class Box
  def put(v)
    @v = v
    self
  end

  def take
    @v
  end
end
b = Box.new
b.put(7)
b.take
