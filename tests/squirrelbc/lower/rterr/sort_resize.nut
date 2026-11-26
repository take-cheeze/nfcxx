// A comparison function that adds to the array it sorts: "array resized during sort operation".
local a = [3, 1, 2];
a.sort(function(x, y) { a.append(0); return 1; });
return 1;
