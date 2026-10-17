// A command interpreter. `break` leaves the innermost switch or loop, `continue`
// skips to the next iteration of the enclosing while loop, and a class value made
// in an arm is released when a `break` leaves that arm.
class Cmd {
  let code: Int
  init(code: Int) {
    self.code = code
  }
  deinit {
    print(self.code)
  }
}

func run(_ cmds: [Int]) -> Int {
  var acc = 0
  var i = 0
  while i < cmds.count {
    let c = cmds[i]
    i = i + 1
    switch c {
    case 0:
      continue
    case 1:
      let cmd = Cmd(code: 100 + i)
      if cmd.code > 102 {
        break
      }
      acc = acc + cmd.code
    case 2:
      acc = acc * 2
      break
    case 3:
      // This break leaves the inner while, not the switch.
      var k = 0
      while k < 10 {
        k = k + 1
        if k == 3 {
          break
        }
      }
      acc = acc + k
    default:
      acc = acc - 1
    }
    acc = acc + 1000
  }
  return acc
}

print(run([0, 1, 2, 3, 4, 1, 0, 1]))
print(run([]))
print(run([1, 3, 2]))
