// A traffic-light state machine driven by a counter, with an enum of states and
// a switch in each transition.
enum Light {
  case red(Int)
  case green(Int)
  case yellow(Int)
}

func next(_ light: Light) -> Light {
  switch light {
  case .red(let t):
    if t == 0 { return .green(3) }
    return .red(t - 1)
  case .green(let t):
    if t == 0 { return .yellow(1) }
    return .green(t - 1)
  case .yellow(let t):
    if t == 0 { return .red(2) }
    return .yellow(t - 1)
  }
}

func code(_ light: Light) -> Int {
  switch light {
  case .red(_):
    return 1
  case .green(_):
    return 2
  case .yellow(_):
    return 3
  }
}

var light = Light.red(2)
var total = 0
var ticks = 0
while ticks < 20 {
  total = total + code(light)
  light = next(light)
  ticks = ticks + 1
}
print(total)
print(code(light))
