// A null from the comparison function is not a number either.
local a = [3, 1];
a.sort(function(x, y) { return null; });
return 1;
