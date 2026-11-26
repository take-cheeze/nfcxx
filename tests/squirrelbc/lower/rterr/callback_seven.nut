// A map with a seven-parameter callback (nargs 8): the callee read below the map's frame is the caller's register
// under the map's `this`, here the array `a`, which is not callable.
local a = [1, 2];
local r = a.map(function(p, b, c, d, e, f, g) { return b; });
return r.len();
