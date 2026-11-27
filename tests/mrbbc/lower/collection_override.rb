class Other
  def <<(v)
    v * 3
  end
  def map
    yield 2
  end
  def first
    8
  end
  def join
    "custom"
  end
end
o = Other.new
[o << 4, o.map { |v| v + 5 }, o.first, o.join, [1, 2].map { |v| v * 2 }, ["a", "b"].join]
