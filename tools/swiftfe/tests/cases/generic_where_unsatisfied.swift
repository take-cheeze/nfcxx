func same<T>(_ a: T, _ b: T) -> Int where T == Int {
  return 0
}

print(same(true, false))
