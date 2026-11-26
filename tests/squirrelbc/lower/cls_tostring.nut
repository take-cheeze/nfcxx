// _tostring of a class: print of an instance, its concatenation with a string, and its tostring method. A derived class
// without its own _tostring takes the base's (the metamethod table is copied at CLASS_OP); one with its own replaces it.
class P {
  x = 0;
  constructor(v) { x = v; }
  function _tostring() { return "P(" + x + ")"; }
}
class Q extends P {
  function _tostring() { return "Q" + x; }
}
class R extends P {}
local p = P(3);
print(p);
print(" ");
print("val=" + p);
print(" ");
print(p.tostring());
print(" ");
print(Q(4));
print(" ");
print(R(5));
print(" ");
return p.tostring().len();
