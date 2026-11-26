// A generator: the prototype's bgenerator flag is set, and yield is an opcode of its own.
function gen(n) {
  for (local i = 0; i < n; i++) {
    yield i * i
  }
  return -1
}
local g = gen(3)
local a = resume g
local b = resume g
return a + b
