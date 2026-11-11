func same<T>(_ a: T, _ b: T) -> Bool where T: Equatable {
  return a == b
}

print(same(1, 2))
