def first
  7
end
class Difference
  def subtract(n)
    20 - n
  end
end
def apply
  yield Difference.new, 5
end
[[Object.new].map(&:first), apply(&:subtract)]
