// A map of an empty array with a five-parameter callback: no item, so no call and no error (__map_array).
local a = [];
local r = a.map(function(p, b, c, d, e) { return 1; });
return r.len();
