// array.sort without a function: ObjCmp order (a heapsort, so the order of equal items is the heap's). Integers, strings,
// floats (-0.0 is not equal to 0.0 in ObjCmp), and a mix of an integer and a float that are equal.
local show = function(arr) {
  local i = 0;
  while (i < arr.len()) { print(arr[i]); print(" "); i = i + 1; }
  print("| ");
};
local a = [5, 3, 9, 1, 7, 2, 8, 3, -4, 0];
show(a.sort());
local s = ["pear", "apple", "fig", "banana", "apple2", ""];
show(s.sort());
local f = [0.5, -0.0, 0.0, 2.25, -1.5, 0.25];
show(f.sort());
local m = [2, 1.0, 1, 0.5, 1.0, 2.0];
show(m.sort());
return a.len() + s.len();
