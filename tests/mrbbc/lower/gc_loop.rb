class Box
  def put(v)
    @v = v
    self
  end

  def take
    @v
  end
end

def two(x, y)
  x + y
end

i = 0
s = 0
while i < 20000
  b = Box.new
  b.put("k" + i.to_s)
  a = [i, 1]
  s += two(*a) + b.take.size + [*a].size
  i += 1
end
s
