class Obj {
  let id: Int
  deinit {
    print(self.id)
  }
}

class Holder<T> {
  var item: T
  var next: Holder<T>?
  deinit {
    print(0)
  }
}

func make<T>(_ x: T) -> Holder<T> {
  let h = Holder(item: x, next: nil)
  return h
}

func f() {
  let a = Holder(item: Obj(id: 1), next: nil)
  a.next = Holder(item: Obj(id: 2), next: nil)
  let kept = make(Obj(id: 3))
  print(kept.item.id)
}

f()
print(7)

func passThrough<T>(_ x: T) -> T {
  return x
}

func g() {
  let z = passThrough(Obj(id: 9))
  print(z.id)
}

g()
