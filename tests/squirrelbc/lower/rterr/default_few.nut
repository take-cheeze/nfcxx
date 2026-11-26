// A call with fewer arguments than the parameters minus the defaults: StartCall's error, with the counts of the parameters.
local f = function(a, b = 2) { return a; };
return f();
