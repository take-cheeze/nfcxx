// Bit operations on Int: popcount and Gray code by bit tests, wrapping arithmetic,
// shifts (including counts that are too large or negative), and remainder.
func popcount(_ n: Int) -> Int {
  var x = n
  var count = 0
  while x != 0 {
    count = count + (x & 1)
    x = x >> 1
  }
  return count
}

var i = 0
while i < 8 {
  print(popcount(i))
  i = i + 1
}

i = 0
while i < 8 {
  print(i ^ (i >> 1))
  i = i + 1
}

let big = 9223372036854775807
print(big &+ 1)
print(-big &- 2)
print(big &* 2)
print(1 << 62)
print(-100 >> 3)
print(-1 << 5)
print(3 << 64)
print(-3 >> 64)
print(-7 % 3)
print(7 % -3)
print(-7 / 2)
print(popcount(big))
