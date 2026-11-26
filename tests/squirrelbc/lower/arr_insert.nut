// array.insert: the value goes before the item at the index (the count is allowed, the end); the result is the array.
local a = [1, 2, 3];
a.insert(0, 9);
a.insert(4, 8);
a.insert(2, 7);
print(a.len()); print(" ");
print(a[0]); print(" ");
print(a[3]); print(" ");
print(a[5]); print(" ");
local r = a.insert(1.9, 5);
print(r == a); print(" ");
return a.find(5);
