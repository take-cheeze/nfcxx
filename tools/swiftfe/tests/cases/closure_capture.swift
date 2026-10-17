func make() -> (Int) -> Int {
  let k = 2
  return { $0 * k }
}
