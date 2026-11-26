class K
  def go
    r = each_val { |v| break v + 1000 }
    r + 1
  end

  def each_val
    yield 7
    0
  end
end
K.new.go
