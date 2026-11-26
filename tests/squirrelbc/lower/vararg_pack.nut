// A vararg function: the parameters before the last one take the first arguments, and the extra ones are packed into the
// array vargv (StartCall). The call with no extra argument gets an empty array.
local f = function(a, ...) { return vargv.len() * 10 + a; };
print(f(1, 2, 3, 4));
print(" ");
local e = function(...) { return vargv.len(); };
print(e());
print(" ");
return e(1, 2);
