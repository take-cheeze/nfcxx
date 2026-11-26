// A comparison function that leaves the array alone: sort gives the sorted array (the same object).
local a = [3, 1, 2];
local r = a.sort(function(x, y) { return x < y ? -1 : (x == y ? 0 : 1); });
return (r == a ? 10 : 0) + a[0] * 100 + a[1] * 10 + a[2];
