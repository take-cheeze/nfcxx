// Loops and branches: for-in over ranges, break and continue (including out of
// scopes that own class references), guard, and switch over Int and Bool with
// ranges and several values per case.
class Tick {
  let n: Int
  init(n: Int) {
    self.n = n
  }
  deinit {
    print(self.n)
  }
}

func firstOver(_ limit: Int) -> Int {
  for i in 0..<100 {
    let t = Tick(n: i)
    if t.n * t.n > limit {
      return t.n
    }
  }
  return -1
}

func describe(_ n: Int) -> Int {
  switch n {
  case 0:
    return 100
  case 1, 2, 3:
    return 200
  case 4...9:
    return 300
  default:
    return 400
  }
}

func sumOdd(_ upTo: Int) -> Int {
  var total = 0
  for i in 1...upTo {
    if i % 2 == 0 {
      continue
    }
    let t = Tick(n: i)
    total = total + t.n
  }
  return total
}

func guarded(_ value: Int?) -> Int {
  guard let v = value else {
    return -1
  }
  guard v > 10 else {
    return 0
  }
  return v * 2
}

var count = 0
for i in 0..<10 {
  if i == 6 {
    break
  }
  if i == 2 {
    continue
  }
  count = count + 1
}
print(count)
print(firstOver(50))
print(describe(0) + describe(2) + describe(5) + describe(42))
print(sumOdd(5))
print(guarded(nil))
print(guarded(4))
print(guarded(12))

var flag = true
switch flag {
case true:
  print(1)
case false:
  print(0)
}
