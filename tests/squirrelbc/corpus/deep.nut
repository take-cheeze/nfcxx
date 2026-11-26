// Several nested prototypes, each with its own outers and locals, and a closure returned from a closure.
function make(a) {
  return function(b) {
    return function(c) {
      return a * 100 + b * 10 + c
    }
  }
}
local f = make(1)(2)
return f(3)
