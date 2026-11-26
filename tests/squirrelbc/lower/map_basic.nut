// array.map, array.apply: the callback gets `this` (the array), the item, and the index when it takes three; map gives a
// new array; apply writes the results into the array and gives the array back.
local a = [1, 2, 3, 4];
local doubled = a.map(function(v) { return v * 2; });
local indexed = a.map(function(v, i) { return v * 10 + i; });
print(doubled[3]); print(" ");
print(indexed[2]); print(" ");
print(a[0]); print(" ");
local r = a.apply(function(v) { return v + 100; });
print(r == a); print(" ");
print(a[3]); print(" ");
local e = [].map(function(v) { return v; });
print(e.len()); print(" ");
local sq = [1, 2, 3].map(function(v, i, a) { return a.len() * 1000 + v * 10 + i; });
return sq[2];
