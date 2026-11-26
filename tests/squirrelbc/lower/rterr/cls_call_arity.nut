// A _call with the wrong number of parameters: the instance is the callee, and the call counts its `this` (CALL).
class F { function _call(a) { return a; } }
local f = F();
return f(1, 2);
