// Calls from calls: g calls f; each frame starts above its caller's registers.
function f(x) { return x * 2; }
function g(x) { local y = f(x) + 1; return y + f(x + 1); }
return g(5);
