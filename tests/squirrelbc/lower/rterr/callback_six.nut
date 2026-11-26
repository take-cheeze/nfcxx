// A map with a six-parameter callback (nargs 7): the callee of the first call is read below the map's frame, the
// caller's register under the map's `this`. The reference reports the wrong parameter count there.
local a = [1, 2];
local r = a.map(function(p, b, c, d, e, f) { return b; });
return r.len();
