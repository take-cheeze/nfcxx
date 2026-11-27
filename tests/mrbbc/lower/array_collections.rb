class FirstBox
  def initialize(v)
    @v = v
  end
  def first
    @v
  end
  def to_s
    "box#{@v}"
  end
end
def pick
  yield [4, 5]
end
def leave_map
  [1, 2, 3].map { |v| return ["return", v] if v == 2; v }
  "unreachable"
end
a = [1]
mapped = a.map { |v| a << v + 1 if v < 4; "x#{v}" }
firsts = [[7, 8], [], [9]].map(&:first)
user = [FirstBox.new(6)].map(&:first)
found = [[1, "a"], [2, "b"]].find { |n, value| n == 2 }
not_found = [1, 2].find { false }
truthy_zero = [1, 2].find { 0 }
each_result = [1, 2].each { |v| [v, "allocate"] }
broken = [1, 2, 3].map { |v| break ["break", v] if v == 2; v }
nested = [1, 2].map { |v| [3, 4].each { |w| break v + w }; v }
source = ["old"]
kept = source.find { |v| source[0] = "new"; temp = ["gc", v]; true }
joined = ["a", [nil, "b", [2]], FirstBox.new(3)].join
[a, mapped, firsts, user, found, not_found, truthy_zero, each_result, broken, leave_map, nested, source, kept, joined, pick(&:first)]
