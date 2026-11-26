// A callback with a vararg is a vararg nested function, which the producer still refuses.
local a = [1, 2];
return a.map(function(...) { return 1; }).len();
