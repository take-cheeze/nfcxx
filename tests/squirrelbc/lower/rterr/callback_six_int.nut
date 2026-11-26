// A six-parameter callback (nargs 7) with an integer local before the array: the register under the map's `this` is
// the integer, and the call reports the wrong parameter count.
local q = 7;
local a = [1, 2];
local r = a.map(function(p, b, c, d, e, f) { return b + q; });
return r.len();
