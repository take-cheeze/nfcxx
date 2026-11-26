// A `+` with a string operand concatenates (StringCat): the instance's _tostring gives its text, and the result is the
// string. An instance on the left of `+` with an integer, not a string, calls _add instead (ARITH_OP).
class S {
  function _tostring() { return "s"; }
  function _add(o) { return 100 + o; }
}
local a = S();
local t = a + "x";
print(t);
print(" ");
print("y" + a);
print(" ");
return a + 1;
