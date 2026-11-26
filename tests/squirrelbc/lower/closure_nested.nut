// An outer variable of an outer variable: the innermost closure takes a from the main function through the middle closure
// (kind outer), and b from the enclosing function (kind local of the middle closure's creator).
local a = 5;
function outer() {
  local b = 10;
  return function() { return function() { return a + b; }; };
}
local mid = outer();
local inner = mid();
return inner();
