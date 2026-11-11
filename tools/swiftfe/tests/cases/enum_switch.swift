enum Shape {
  case circle(Int)
  case rect(Int, Int)
  case empty
}
func area(_ s: Shape) -> Int {
  switch s {
  case .circle(let r):
    return r * r * 3
  case .rect(let w, let h):
    return w * h
  case .empty:
    return 0
  }
}
print(area(Shape.circle(2)))
print(area(Shape.rect(3, 4)))
print(area(.empty))
