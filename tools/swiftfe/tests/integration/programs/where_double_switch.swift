// for-in with a where clause over an array and over a range, with continue and break
// in the loop, and switch over Double with literal, range and default cases.
func sumAbove(_ xs: [Int], _ limit: Int) -> Int {
  var total = 0
  for x in xs where x > limit {
    total = total + x
  }
  return total
}

func firstEvenUnder(_ xs: [Int], _ cap: Int) -> Int {
  for x in xs where x % 2 == 0 {
    if x > cap {
      break
    }
    if x == 0 {
      continue
    }
    return x
  }
  return -1
}

func kind(_ d: Double) -> Int {
  switch d {
  case 0.5:
    return 1
  case -2.0, 2.0:
    return 2
  case 1:
    return 3
  case 0.0..<1.0:
    return 4
  default:
    return 5
  }
}

print(sumAbove([4, 1, 7, 3, 9], 3))
print(firstEvenUnder([1, 0, 4, 8], 5))
print(firstEvenUnder([1, 0, 6, 8], 5))

var picked = 0
for i in 1...10 where i % 4 == 0 {
  picked = picked + i
}
print(picked)

for i in 0..<12 where i % 3 != 0 {
  if i == 7 {
    break
  }
  print(i)
}

var sum = 0
var v = 0.0
while v < 3.0 {
  sum = sum + kind(v)
  v = v + 0.5
}
print(sum)
print(kind(-0.5))
print(kind(1.0))

let ds: [Double] = [0.5, 1.0, -2.0, 9.0]
for x in ds where x != 9.0 {
  switch x {
  case 1.0:
    continue
  default:
    print(kind(x))
  }
}
