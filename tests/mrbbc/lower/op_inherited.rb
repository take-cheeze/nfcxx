class A
  def +(o)
    1 + o
  end
end
class B < A
end
class C < B
  def ==(o)
    true
  end
end
[B.new + 2, C.new == 3, [C.new] == [C.new]]
