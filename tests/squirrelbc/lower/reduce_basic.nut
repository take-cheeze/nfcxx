// array.reduce: the first item is the start when there is no initial value; the callback gets `this`, the accumulated value
// and the item. An empty array gives the initial value, or null with none.
local sum = function(acc, v) { return acc + v; };
local cat = function(acc, v) { return acc * 10 + v; };
print([1, 2, 3, 4].reduce(sum)); print(" ");
print([1, 2, 3].reduce(cat, 0)); print(" ");
print([7].reduce(sum)); print(" ");
print([].reduce(sum, 5)); print(" ");
print([].reduce(sum) == null); print(" ");
local n = [2, 3].reduce(function(acc, v) { return acc == null ? v : acc * v; });
return n;
