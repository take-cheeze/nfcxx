def pair
  yield [3, 4]
end
def two
  yield 5, 6
end
def one
  yield 5
end
x = pair { |a, b| a * b }
y = two { |a, b| a - b }
z = one { |a, b| b }
[x, y, z]
