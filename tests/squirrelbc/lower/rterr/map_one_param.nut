// A callback with one parameter (`this` only): map pushes the array below the item and calls that, so it is "attempt to call 'array'".
local a = [1, 2];
return a.map(function() { return 1; }).len();
