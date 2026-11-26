// append (its result is the array), push, pop, reverse, find and slice of an array.
local a = [1, 2];
local r = a.append(3);
print(r == a); print(" ");
a.push(4);
print(a.len()); print(" ");
print(a.pop()); print(" ");
print(a.len()); print(" ");
a.reverse();
print(a.find(2)); print(" ");
print(a.find(77)); print(" ");
local s = a.slice(1);
print(s.len()); print(" ");
print(a.slice(0, 2)[1]); print(" ");
print(a.slice(-2)[0]); print(" ");
print(a.slice(1.5, 2.9).len()); print(" ");
return a[0];
