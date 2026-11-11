struct Bag {
  var items: [Int]
  var n: Int
}

func make() -> Bag {
  return Bag(items: [1], n: 2)
}

print(make().n)
