class Box {
  let v: Int
  deinit {
    print(self.v)
  }
}
func make(_ v: Int) -> Box {
  let b = Box(v: v)
  return b
}
let kept = make(7)
print(kept.v)
