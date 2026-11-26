// Outers, nested prototypes and default parameters.
local top = 10
local adder = function(x, y = 5) {
  local inner = function(z) { return top + x + y + z }
  return inner(1)
}
local counter = 0
local bump = function() { counter = counter + 1; return counter }
bump()
bump()
return adder(2) + counter
