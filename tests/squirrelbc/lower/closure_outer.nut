// A function that reads a local of the enclosing function (an outer variable of kind local, read by GETOUTER).
local x = 1;
function f(y) { return x + y; }
return f(41);
