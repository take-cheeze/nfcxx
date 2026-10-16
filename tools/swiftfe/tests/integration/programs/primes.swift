// Count primes below a limit by trial division, and report the largest one.
func isPrime(_ n: Int) -> Bool {
  if n < 2 {
    return false
  }
  var d = 2
  while d * d <= n {
    if n % d == 0 {
      return false
    }
    d = d + 1
  }
  return true
}

var count = 0
var largest = 0
var n = 0
while n < 500 {
  if isPrime(n) {
    count = count + 1
    largest = n
  }
  n = n + 1
}
print(count)
print(largest)
