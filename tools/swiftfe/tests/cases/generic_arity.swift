struct Box<T> {
  var value: T
}

let b: Box<Int, Bool> = Box(value: 1)
print(b.value)
