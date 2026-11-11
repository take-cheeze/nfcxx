// An initializer that checks its arguments and returns early. The local buffer it
// made is released by that return, and the object keeps no reference to it.
class Buffer {
  let size: Int
  init(size: Int) {
    self.size = size
  }
  deinit {
    print(self.size)
  }
}

class Window {
  let width: Int
  let height: Int
  var frame: Buffer?
  init(width: Int, height: Int) {
    self.width = width
    self.height = height
    self.frame = nil
    let scratch = Buffer(size: width * height)
    if width <= 0 || height <= 0 {
      return
    }
    self.frame = scratch
  }
}

let w = Window(width: 3, height: 4)
print(w.width * w.height)
if let f = w.frame {
  print(f.size)
}
let z = Window(width: 0, height: 2)
print(z.frame == nil)
