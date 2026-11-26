// A map with a four-parameter callback (five with `this`): sq_call takes the callee from the copy of the callback that
// __map_array pushed, and the four values after it are the array, the item, the index and the array. On one item the
// result is the callback's.
local a = [5];
local r = a.map(function(p, b, c, d) { return b * 10 + c; });
return r[0];
