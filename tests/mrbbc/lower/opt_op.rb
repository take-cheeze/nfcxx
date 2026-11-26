class V
  def +(o, k = 10)
    o + k
  end
end
[V.new + 1, V.new.+(1, 2)]
