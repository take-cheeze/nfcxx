// Two closures over the same local share it: a write through one is seen through the other, and the main function sees
// both (its local is still open while main runs).
local x = 1;
local inc = function() { x = x + 1; };
local get = function() { return x; };
inc();
inc();
return get() * 10 + x;
