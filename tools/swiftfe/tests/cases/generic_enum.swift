enum Maybe<T> {
  case some(T)
  case none
}

func describe(_ m: Maybe<Int>) -> Int {
  switch m {
  case .some(let v):
    return v
  case .none:
    return -1
  }
}

let a = Maybe<Int>.some(3)
let b: Maybe<Bool> = .some(true)
let c = Maybe.some(4)
let d: Maybe<Int> = Maybe<Int>.none
print(describe(a))
print(describe(c))
print(describe(d))
switch b {
case .some(let x):
  print(x)
case .none:
  print(0)
}
