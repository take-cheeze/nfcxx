// A singly linked list of classes, built with optionals and walked with
// if-let and while-let. Each node is released once the list goes away.
class Cell {
  let value: Int
  var next: Cell?
  init(value: Int, next: Cell?) {
    self.value = value
    self.next = next
  }
  deinit {
    print(value)
  }
}

func build(_ count: Int) -> Cell? {
  var head: Cell? = nil
  var i = 0
  while i < count {
    head = Cell(value: i, next: head)
    i = i + 1
  }
  return head
}

func sum(_ head: Cell?) -> Int {
  var total = 0
  var current = head
  while let cell = current {
    total = total + cell.value
    current = cell.next
  }
  return total
}

func scope() {
  let list = build(4)
  print(sum(list))
}

scope()
print(0)
