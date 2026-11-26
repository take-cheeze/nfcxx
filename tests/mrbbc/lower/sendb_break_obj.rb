class Source
  def each
    yield 1
    yield 2
    9
  end
end
Source.new.each { |v| break v * 7 if v == 2 }
