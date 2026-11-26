// A comparison that never returns a negative value for the top of the heap: "inconsistent compare function".
local a = [3, 1, 2, 5, 4];
a.sort(function(x, y) { return x < y ? 1 : -1; });
return a[0];
