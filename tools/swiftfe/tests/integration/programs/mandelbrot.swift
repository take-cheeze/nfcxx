// Mandelbrot membership on a small grid. Each cell iterates z = z*z + c up to a cap and
// reports how many iterations it took to escape. Prints the inside count per row, then
// the total inside count and the total iteration count as a checksum.
func escapeCount(_ cr: Double, _ ci: Double, _ limit: Int) -> Int {
  var zr = 0.0
  var zi = 0.0
  var k = 0
  while k < limit {
    let zr2 = zr * zr
    let zi2 = zi * zi
    if zr2 + zi2 > 4.0 {
      return k
    }
    let nzr = zr2 - zi2 + cr
    zi = 2.0 * zr * zi + ci
    zr = nzr
    k = k + 1
  }
  return limit
}

let width = 40
let height = 20
let maxIter = 50

var row = 0
var insideTotal = 0
var iterTotal = 0
while row < height {
  let ci = -1.2 + 2.4 * Double(row) / Double(height - 1)
  var rowInside = 0
  var col = 0
  while col < width {
    let cr = -2.2 + 3.0 * Double(col) / Double(width - 1)
    let k = escapeCount(cr, ci, maxIter)
    if k == maxIter {
      rowInside = rowInside + 1
    }
    iterTotal = iterTotal + k
    col = col + 1
  }
  print(rowInside)
  insideTotal = insideTotal + rowInside
  row = row + 1
}
print(insideTotal)
print(iterTotal)
