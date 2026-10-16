func same<T>(_ a: T, _ b: T) -> Int where T == Int {
  return a + b
}

print(same(1, 2))
