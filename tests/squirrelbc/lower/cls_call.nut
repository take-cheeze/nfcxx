// _call of a class: a call of an instance calls _call with the instance as `this` and the call's values as parameters
// (the first is the caller's `this` value, as the reference passes it).
class F {
  function _call(t, a, b) { return a + b; }
}
local f = F();
return f(2, 3);
