func zero<T>() -> T where T == Int {
  return 0
}

func unit<T>() -> T where T == Double {
  return 1.5
}

let z = zero()
print(z + 5)
print(unit() * 2.0)
