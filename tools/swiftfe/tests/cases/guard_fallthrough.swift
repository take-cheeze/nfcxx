func f(_ x: Int?) -> Int {
  guard let v = x else {
    print(0)
  }
  return v
}
