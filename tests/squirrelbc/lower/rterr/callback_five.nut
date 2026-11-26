// A map with a five-parameter callback: the callee of the first call is the array (the map's own this).
local a = [1, 2];
local r = a.map(function(p, b, c, d, e) { return b; });
return r.len();
