// A callback that is a vararg function: map passes the callback's parameter count (this and vargv: two values), so vargv is
// the item alone, and the result is one value per item.
local r = [1, 2].map(function(...) { return vargv.len(); });
print(r[0]);
print(" ");
return r.len();
