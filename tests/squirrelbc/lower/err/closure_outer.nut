// A closure over a local of the enclosing function: its outer variable needs GETOUTER and a captured slot (not lowered).
local x = 1;
function f() { return x; }
return f();
