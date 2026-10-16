func show(_ x: Int?) {
  if let v = x {
    print(v)
  } else {
    print(0)
  }
}
show(4)
show(nil)
let y: Int? = nil
print(y == nil)
var z: Int? = 9
z = nil
print(z == nil)
print(z!)
