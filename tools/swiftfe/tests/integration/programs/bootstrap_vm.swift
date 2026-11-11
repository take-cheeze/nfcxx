// Bootstrap step 2: a one-pass compiler from integer arithmetic to stack-machine code, and
// a virtual machine that runs the code. The source is an array of character codes, as in
// bootstrap_eval.swift, since the subset has no String.

enum Op {
  case push(Int)
  case add
  case sub
  case mul
  case div
}

enum Tok {
  case num(Int)
  case plus
  case minus
  case star
  case slash
  case lparen
  case rparen
  case end
}

func isDigit(_ c: Int) -> Bool {
  return c >= 48 && c <= 57
}

func lex(_ src: [Int]) -> [Tok] {
  var out: [Tok] = []
  var i = 0
  while i < src.count {
    let c = src[i]
    if c == 32 {
      i = i + 1
    } else if isDigit(c) {
      var v = 0
      while i < src.count && isDigit(src[i]) {
        v = v * 10 + (src[i] - 48)
        i = i + 1
      }
      out.append(.num(v))
    } else {
      if c == 43 {
        out.append(.plus)
      } else if c == 45 {
        out.append(.minus)
      } else if c == 42 {
        out.append(.star)
      } else if c == 47 {
        out.append(.slash)
      } else if c == 40 {
        out.append(.lparen)
      } else {
        out.append(.rparen)
      }
      i = i + 1
    }
  }
  out.append(.end)
  return out
}

// Emits code while parsing, so the parser is also the code generator.
class Compiler {
  let toks: [Tok]
  var pos: Int
  var code: [Op]

  init(_ toks: [Tok]) {
    self.toks = toks
    self.pos = 0
    self.code = []
  }

  func peek() -> Tok {
    return toks[pos]
  }

  func advance() {
    pos = pos + 1
  }

  // expr := term (('+' | '-') term)*
  func expr() {
    term()
    var more = true
    while more {
      switch peek() {
      case .plus:
        advance()
        term()
        code.append(.add)
      case .minus:
        advance()
        term()
        code.append(.sub)
      default:
        more = false
      }
    }
  }

  // term := factor (('*' | '/') factor)*
  func term() {
    factor()
    var more = true
    while more {
      switch peek() {
      case .star:
        advance()
        factor()
        code.append(.mul)
      case .slash:
        advance()
        factor()
        code.append(.div)
      default:
        more = false
      }
    }
  }

  // factor := num | '(' expr ')'
  func factor() {
    switch peek() {
    case .num(let n):
      advance()
      code.append(.push(n))
    case .lparen:
      advance()
      expr()
      advance()
    default:
      advance()
      code.append(.push(0))
    }
  }
}

// Runs code on a stack. The stack has a fixed number of slots; sp is the next free one.
func run(_ code: [Op]) -> Int {
  var stack = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
  var sp = 0
  for op in code {
    switch op {
    case .push(let n):
      stack[sp] = n
      sp = sp + 1
    case .add:
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] + stack[sp]
    case .sub:
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] - stack[sp]
    case .mul:
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] * stack[sp]
    case .div:
      sp = sp - 1
      stack[sp - 1] = stack[sp - 1] / stack[sp]
    }
  }
  return stack[0]
}

func report(_ src: [Int]) {
  let c = Compiler(lex(src))
  c.expr()
  print(run(c.code))
  print(c.code.count)
}

report([49, 43, 50, 42, 51])
report([40, 49, 43, 50, 41, 42, 51])
report([49, 48, 45, 52, 45, 51])
report([49, 48, 48, 47, 55, 47, 50])
report([50, 42, 40, 51, 43, 52, 41, 42, 53])
report([55, 45, 49, 48])
report([40, 40, 56, 41, 41])
report([49, 43, 50, 42, 51, 45, 52, 47, 50])
