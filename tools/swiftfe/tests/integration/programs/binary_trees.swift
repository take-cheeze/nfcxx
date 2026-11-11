// Binary trees, in the style of the benchmarks game: allocate and free many
// class-based trees, checking each by a recursive count.
class Node {
  let left: Node?
  let right: Node?
  init(left: Node?, right: Node?) {
    self.left = left
    self.right = right
  }
}

func make(_ depth: Int) -> Node {
  if depth == 0 {
    return Node(left: nil, right: nil)
  }
  return Node(left: make(depth - 1), right: make(depth - 1))
}

func check(_ node: Node) -> Int {
  if let l = node.left, let r = node.right {
    return 1 + check(l) + check(r)
  }
  return 1
}

let maxDepth = 6
var total = 0
var depth = 4
while depth <= maxDepth {
  let iterations = 1
  var i = 0
  while i < iterations {
    total = total + check(make(depth))
    i = i + 1
  }
  depth = depth + 2
}
print(total)
