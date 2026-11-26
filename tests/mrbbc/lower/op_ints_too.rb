class N
  def +(o)
    9
  end

  def -(o)
    o * 3
  end

  def *(o)
    6
  end

  def /(o)
    8
  end
end
n = N.new
[n + 1, n - 2, n * 3, n / 4, 1 + 2, 7 - 1, 2 * 3, 9 / 2]
