// Arrays of value elements: literals, subscripts, count, append, for-in, value
// semantics on copy, and passing them to functions.
struct Pair {
  var a: Int
  var b: Int
}

func total(_ xs: [Int]) -> Int {
  var sum = 0
  for x in xs {
    sum = sum + x
  }
  return sum
}

func squares(_ n: Int) -> [Int] {
  var out: [Int] = []
  for i in 0..<n {
    out.append(i * i)
  }
  return out
}

var primes = [2, 3, 5, 7]
primes.append(11)
print(primes)
print(primes.count)
print(primes[0] + primes[4])

var copy = primes
copy[0] = 100
print(primes[0])
print(copy[0])

print(total(squares(5)))
print(squares(4))

let ratios = [0.5, 0.25, 2.0]
print(ratios)
print(ratios[2] * 3.0)

let flags: [Bool] = [true, false]
print(flags)

var pairs: [Pair] = []
pairs.append(Pair(a: 1, b: 2))
pairs.append(Pair(a: 3, b: 4))
pairs[1].a = 30
print(pairs[1].a + pairs[0].b)

var n = 0
for x in primes {
  if x == 5 {
    continue
  }
  if x > 7 {
    break
  }
  n = n + x
}
print(n)

var grid: [Int] = []
var i = 0
while i < 6 {
  grid.append(i % 3)
  i = i + 1
}
print(grid)
