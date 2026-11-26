// An arithmetic on the right of an instance has no metamethod: the left operand is an integer (ArithMetaMethod).
class V { n = 1; function _sub(o) { return n - o; } }
local a = V();
return 2 - a;
