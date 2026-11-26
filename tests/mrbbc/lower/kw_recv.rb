class P
  def m(a, *r, k: 0, z: 1)
    [a, r, k, z]
  end
end
pp = P.new
[pp.m(1), pp.m(1, 2, k: 3), pp.m(4, 5, 6, z: 7)]
