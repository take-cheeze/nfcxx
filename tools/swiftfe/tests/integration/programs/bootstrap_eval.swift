// Bootstrap step: an evaluator for integer arithmetic (+ - * /, parentheses), written in
// the subset that swiftfe compiles. The source is an array of character codes, since the
// subset has no String. A lexer makes tokens and a recursive-descent parser evaluates them.

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

class Parser {
  let toks: [Tok]
  var pos: Int

  init(_ toks: [Tok]) {
    self.toks = toks
    self.pos = 0
  }

  func peek() -> Tok {
    return toks[pos]
  }

  func advance() {
    pos = pos + 1
  }

  // expr := term (('+' | '-') term)*
  func expr() -> Int {
    var v = term()
    var more = true
    while more {
      switch peek() {
      case .plus:
        advance()
        v = v + term()
      case .minus:
        advance()
        v = v - term()
      default:
        more = false
      }
    }
    return v
  }

  // term := factor (('*' | '/') factor)*
  func term() -> Int {
    var v = factor()
    var more = true
    while more {
      switch peek() {
      case .star:
        advance()
        v = v * factor()
      case .slash:
        advance()
        v = v / factor()
      default:
        more = false
      }
    }
    return v
  }

  // factor := num | '(' expr ')'
  func factor() -> Int {
    switch peek() {
    case .num(let n):
      advance()
      return n
    case .lparen:
      advance()
      let v = expr()
      advance()
      return v
    default:
      advance()
      return 0
    }
  }
}

func evaluate(_ src: [Int]) -> Int {
  let p = Parser(lex(src))
  return p.expr()
}

print(evaluate([49, 43, 50, 42, 51]))
print(evaluate([40, 49, 43, 50, 41, 42, 51]))
print(evaluate([49, 48, 45, 52, 45, 51]))
print(evaluate([49, 48, 48, 47, 55, 47, 50]))
print(evaluate([50, 42, 40, 51, 43, 52, 41, 42, 53]))
print(evaluate([55, 45, 49, 48]))
print(evaluate([40, 40, 56, 41, 41]))
print(evaluate([49, 43, 50, 42, 51, 45, 52, 47, 50]))
