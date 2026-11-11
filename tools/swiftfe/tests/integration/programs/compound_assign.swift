// Compound assignment (+=, -=, *=, /=) on Int and Double array elements and locals.
func pick(_ i: Int) -> Int {
  print(i)
  return i
}

var values = [1, 2, 3, 4]
values[pick(1)] += 10
values[pick(3)] *= 3
values[0] -= 5
values[2] /= 2
values[0] += pick(2)
print(values[0])
print(values[1])
print(values[2])
print(values[3])

var weights: [Double] = [0.5, 2.0]
weights[1] *= 1.5
weights[0] += 0.25
print(weights[0])
print(weights[1])

var total = 0
var k = 0
while k < 4 {
  total += values[k]
  k += 1
}
print(total)
