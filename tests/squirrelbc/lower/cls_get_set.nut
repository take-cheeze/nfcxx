// _get and _set of a class: a miss on an instance calls _get with the key; a SET of a name that is not a field calls _set
// with the key and the value. A field is read and written directly (no metamethod). The methods write to an outer array,
// not through print: an unqualified name in a method is looked up on `this` first, so _get would take it.
local log = [];
class G {
  x = 1;
  function _get(k) { return "got " + k; }
  function _set(k, v) { log.append("set " + k + "=" + v); }
}
local g = G();
print(g.x);
print(" ");
print(g.foo);
print(" ");
g.x = 5;
print(g.x);
print(" ");
g.y = 7;
print(log[0]);
print(" ");
return g.x + 1;
