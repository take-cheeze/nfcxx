enum Color {
  case red
  case green
}
func name(_ c: Color) -> Int {
  switch c {
  case .red:
    return 1
  }
}
