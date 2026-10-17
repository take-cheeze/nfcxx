func same<T: Equatable>(_ a: T, _ b: T) -> Bool {
  return a == b
}

print(same(1, 2))
