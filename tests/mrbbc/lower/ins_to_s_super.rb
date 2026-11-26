class A
  def to_s
    "A"
  end
end
class B < A
  def to_s
    super + "b"
  end
end
"<#{B.new}>"
