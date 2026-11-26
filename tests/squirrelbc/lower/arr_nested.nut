// Arrays in an array, and an array passed to a function that reads it.
function second(v) { return v[1]; }
local inner = [7, 8];
local outer = [inner, [9, 10]];
return second(outer[0]) + second(outer[1]) + outer.len();
