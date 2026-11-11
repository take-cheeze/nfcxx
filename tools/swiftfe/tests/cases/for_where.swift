// for-in with a where clause over an array and over a range. The clause filters the
// elements, and continue and break act on the elements that pass it.
func sumAbove(_ xs: [Int], _ limit: Int) -> Int {
  var total = 0
  for x in xs where x > limit {
    total = total + x
  }
  return total
}

func show(_ xs: [Int]) {
  for x in xs where x > 2 {
    if x == 5 {
      continue
    }
    if x == 8 {
      break
    }
    print(x)
  }
}

print(sumAbove([4, 1, 7, 3, 9], 3))
print(sumAbove([1, 2], 5))
show([1, 3, 5, 4, 8, 6])
for i in 0..<10 where i % 3 == 0 {
  print(i)
}
for i in 1...6 where i % 2 == 0 {
  if i == 4 {
    continue
  }
  print(i)
}
