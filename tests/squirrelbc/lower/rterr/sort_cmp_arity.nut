// The comparison function is called with three values (this, x, y): one with two parameters is a count error.
local a = [3, 1, 2];
a.sort(function(x, y) { return x - y; });
a.sort(function(x) { return 0; });
return 1;
