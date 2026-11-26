// A vararg function called with fewer arguments than its fixed parameters: StartCall's "at least" message.
local f = function(a, b, ...) { return 1; };
return f(1);
