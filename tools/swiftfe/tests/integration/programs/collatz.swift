// Longest Collatz chain below a limit, with the number that starts it.
func steps(_ start: Int) -> Int {
  var n = start
  var count = 0
  while n != 1 {
    if n % 2 == 0 {
      n = n / 2
    } else {
      n = 3 * n + 1
    }
    count = count + 1
  }
  return count
}

var best = 1
var bestSteps = 0
var candidate = 1
while candidate < 300 {
  let s = steps(candidate)
  if s > bestSteps {
    best = candidate
    bestSteps = s
  }
  candidate = candidate + 1
}
print(best)
print(bestSteps)
