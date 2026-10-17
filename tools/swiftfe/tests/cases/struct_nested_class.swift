class C {
  let x: Int
  init(x: Int) {
    self.x = x
  }
}

struct Inner {
  var items: [Int]
  var c: C
}

struct Outer {
  var inner: Inner
}

func f(_ o: Outer) -> Int {
  return o.inner.items.count
}
