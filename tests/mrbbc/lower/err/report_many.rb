def f(&b)
  b.call
end
class C
  def g
    $a = 1.5
  end
end
x = 3
x.abs
