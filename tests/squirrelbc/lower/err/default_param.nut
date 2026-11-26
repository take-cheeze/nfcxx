// A default parameter: the missing argument comes from the closure's default values (not lowered).
function f(a, b = 2) { return a + b; }
return f(1);
