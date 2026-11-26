// An eight-parameter callback (nargs 9) with a string local before the array: the callee read below the map's frame
// is a string, which is not callable.
local s = "x";
local a = [1, 2];
local r = a.map(function(p, b, c, d, e, f, g, h) { return b + s.len(); });
return r.len();
