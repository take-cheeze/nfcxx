// The comparison function must return a number: a string is "numeric value expected as return value of the compare function".
local a = [3, 1, 2];
a.sort(function(x, y) { return "x"; });
return 1;
