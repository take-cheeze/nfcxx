// array.extend: the items of the argument are appended, and the result is the array itself.
local a = [1, 2];
local r = a.extend([3, 4]);
print(r == a); print(" ");
print(a.len()); print(" ");
print(a[3]); print(" ");
local b = [];
b.extend([]);
print(b.len()); print(" ");
return a.find(4);
