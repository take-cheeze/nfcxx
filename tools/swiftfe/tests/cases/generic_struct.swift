struct Box<T> {
  var value: T
}

struct Pair<A, B> {
  var first: A
  var second: B
}

func unbox<T>(_ b: Box<T>) -> T {
  return b.value
}

func rebox<T>(_ x: T) -> Box<T> {
  return Box(value: x)
}

var a = Box<Int>(value: 1)
var b = Box(value: true)
var p = Pair(first: 2, second: false)
var nested = Box(value: Box(value: 5))
a.value = a.value + 10
print(a.value)
print(b.value)
print(p.first)
print(p.second)
print(nested.value.value)
print(unbox(a))
print(unbox(rebox(9)))
let q: Box<Int> = Box(value: 4)
print(q.value)
