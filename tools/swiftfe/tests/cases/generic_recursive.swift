struct Wrap<T> {
  var v: T
}

struct Loop {
  var w: Wrap<Loop>
}

print(1)
