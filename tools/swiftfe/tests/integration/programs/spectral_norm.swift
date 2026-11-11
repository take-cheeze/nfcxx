// Spectral norm of the infinite matrix A(i, j) = 1 / ((i+j)(i+j+1)/2 + i + 1), restricted to
// an n x n section, by power iteration on A transposed times A (benchmarks-game algorithm).
// The subset has no sqrt, so the final square root is Newton's method with a fixed number of
// steps, which keeps the printed value reproducible.
func evalA(_ i: Int, _ j: Int) -> Double {
  let ij = i + j
  return 1.0 / Double(ij * (ij + 1) / 2 + i + 1)
}

func timesAv(_ v: [Double], _ n: Int) -> [Double] {
  var out: [Double] = []
  var i = 0
  while i < n {
    var sum = 0.0
    var j = 0
    while j < n {
      sum = sum + evalA(i, j) * v[j]
      j = j + 1
    }
    out.append(sum)
    i = i + 1
  }
  return out
}

func timesAtv(_ v: [Double], _ n: Int) -> [Double] {
  var out: [Double] = []
  var i = 0
  while i < n {
    var sum = 0.0
    var j = 0
    while j < n {
      sum = sum + evalA(j, i) * v[j]
      j = j + 1
    }
    out.append(sum)
    i = i + 1
  }
  return out
}

func timesAtAv(_ v: [Double], _ n: Int) -> [Double] {
  return timesAtv(timesAv(v, n), n)
}

func dot(_ a: [Double], _ b: [Double], _ n: Int) -> Double {
  var s = 0.0
  var i = 0
  while i < n {
    s = s + a[i] * b[i]
    i = i + 1
  }
  return s
}

func squareRoot(_ a: Double) -> Double {
  var x = 1.0
  var k = 0
  while k < 60 {
    x = 0.5 * (x + a / x)
    k = k + 1
  }
  return x
}

let n = 100
var u: [Double] = []
var start = 0
while start < n {
  u.append(1.0)
  start = start + 1
}

var v: [Double] = []
var iter = 0
while iter < 10 {
  v = timesAtAv(u, n)
  u = timesAtAv(v, n)
  iter = iter + 1
}

let vBv = dot(u, v, n)
let vv = dot(v, v, n)
print(squareRoot(vBv / vv))
