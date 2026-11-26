// array.filter: the callback gets `this`, the index and the item; the items for which it is not false are kept, in order.
local a = [5, 0, 7, null, 2, false, 9];
local kept = a.filter(function(i, v) { return v; });
local i = 0;
while (i < kept.len()) { print(kept[i]); print(" "); i = i + 1; }
print("| ");
local evens = [1, 2, 3, 4, 5, 6].filter(function(i, v) { return v % 2 == 0; });
print(evens.len()); print(" ");
local idx = [9, 8, 7, 6].filter(function(i, v) { return i > 1; });
return idx[0] + idx[1];
