// array.sort with a comparison function: its result is an integer (a float is truncated, a boolean is 0 or 1).
local show = function(arr) {
  local i = 0;
  while (i < arr.len()) { print(arr[i]); print(" "); i = i + 1; }
  print("| ");
};
local a = [4, 8, 1, 9, 3, 7];
show(a.sort(function(x, y) { return y - x; }));
local b = [4, 8, 1, 9, 3, 7];
show(b.sort(function(x, y) { return x < y ? -1.5 : 2.9; }));
local c = [4, 8, 1, 9, 3, 7];
show(c.sort(function(x, y) { return x > y; }));
local d = ["b", "c", "a", "bb"];
show(d.sort(function(x, y) { return x == y ? 0 : (x < y ? -1 : 1); }));
local e = [3, 1, 2];
e.sort(function(x, y) { return x - y; });
return e[0] * 100 + e[1] * 10 + e[2];
