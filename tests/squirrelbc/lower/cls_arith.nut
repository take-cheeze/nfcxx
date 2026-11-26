// The arithmetic metamethods of a class: the left operand's metamethod is called with the right operand as its parameter
// (_add, _sub, _mul, _div, _modulo), and the unary minus calls _unm with no parameter (ArithMetaMethod, NEG_OP).
class V {
  n = 0;
  constructor(v) { n = v; }
  function _add(o) { return n + o.n; }
  function _sub(o) { return n - o; }
  function _mul(o) { return n * o; }
  function _div(o) { return n / o; }
  function _modulo(o) { return n % o; }
  function _unm() { return 0 - n; }
}
local a = V(7);
local b = V(3);
print(a + b);
print(" ");
print(a - 2);
print(" ");
print(a * 3);
print(" ");
print(a / 2);
print(" ");
print(a % 4);
print(" ");
print(-a);
print(" ");
return a + b;
