// Default parameters of a nested function: a call with fewer arguments takes the last defaults, from the values the closure
// got when it was made (CLOSURE_OP copies them; StartCall fills the missing parameters from them).
local f = function(a, b = 2, c = 30) { return a * 100 + b * 10 + c; };
print(f(1));
print(" ");
print(f(1, 5));
print(" ");
print(f(1, 5, 7));
print(" ");
return f(4);
