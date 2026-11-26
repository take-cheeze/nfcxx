class Source
  def each
    yield 1
    yield 2
    9
  end
end
s = 0
x = Source.new.each { |v| s += v }
s + x
