// A default parameter taken from a local: the closure has the local's value when it is made, so a later change of the
// local does not change the default (CLOSURE_OP copies the register).
local k = 7;
local g = function(a, b = k) { return a + b; };
print(g(1));
print(" ");
k = 9;
print(g(1));
print(" ");
return g(1, 1);
