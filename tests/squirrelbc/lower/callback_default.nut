// A callback with a default parameter: map passes the callback's whole parameter count (this, the item and the index), so
// the default is not used, and the index is the second parameter's value.
local r = [1, 2].map(function(v, d = 2) { return v + d; });
print(r[1]);
print(" ");
return r.len();
