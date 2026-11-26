function f(x) { return x + 1; }
function g(x) { return f(f(x)) * 2; }
var result = g(g(1));
