// A parameter captured by a closure that the function returns: the parameter is an outer variable of kind local.
function adder(n) { return function(x) { return x + n; }; }
local add5 = adder(5);
local add7 = adder(7);
return add5(10) * 100 + add7(1);
