class Tok {
  let id: Int
  init(id: Int) {
    self.id = id
  }
  deinit {
    print(self.id)
  }
}

func pick(_ n: Int) -> Int {
  switch n {
  case 0:
    let t = Tok(id: 1)
    if t.id == 1 {
      break
    }
    return 5
  case 1:
    return 7
  default:
    print(n)
  }
  return 9
}

var total = 0
for i in 0..<6 {
  switch i {
  case 1:
    total = total + 10
    break
  case 2:
    continue
  case 3:
    if total > 5 {
      break
    }
    total = total + 1000
  default:
    total = total + 1
  }
  total = total + 100
}
print(total)
print(pick(0))
print(pick(1))
print(pick(4))
