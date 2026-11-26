// A SET past the end of an array: the index error, not an append.
local a = [1, 2];
a[2] = 9;
return 0;
