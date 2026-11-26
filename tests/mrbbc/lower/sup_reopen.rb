class A
  def hi
    3
  end
end
class C < A
end
class C < A
  def g
    2
  end
end
C.new.g + C.new.hi
