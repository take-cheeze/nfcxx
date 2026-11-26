// A runtime error raised inside a callback reaches the caller unchanged: division by zero in the map's function.
local a = [4, 0, 2];
return a.map(function(v) { return 8 / v; }).len();
