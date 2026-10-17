// switch over Double with literal, several-value, integer, negative, range and default
// cases. The first matching case runs, and the default runs when none matches.
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

func band(_ d: Double) -> Int {
  switch d {
  case 0..<1.0:
    return 10
  case 1.0...2.5:
    return 20
  default:
    return 30
  }
}

func report(_ d: Double) {
  switch d {
  case 0.25:
    print(1)
  case 0.75:
    print(2)
  default:
    print(3)
  }
}

print(kind(0.5))
print(kind(-2.0))
print(kind(2.0))
print(kind(1.0))
print(kind(0.25))
print(kind(-0.5))
print(band(0.5))
print(band(1.0))
print(band(2.5))
print(band(2.6))
print(band(-0.5))
report(0.75)
report(0.5)
