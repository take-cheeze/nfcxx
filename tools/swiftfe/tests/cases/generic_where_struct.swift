struct Scale<T> where T == Double {
  var factor: T
}

let s = Scale<Int>(factor: 2)
print(s.factor)
