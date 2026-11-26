// _cmp of a class: the comparison of two instances calls the left one's _cmp with the right one (ObjCmp), and the result
// of the operator is its sign. The default sort of an array of instances orders them by _cmp too.
class K {
  v = 0;
  constructor(x) { v = x; }
  function _cmp(o) { return 10 * (v - o.v); }
}
local a = K(1);
local b = K(5);
local c = K(5);
print(a < b);
print(" ");
print(b <= c);
print(" ");
print(a > b);
print(" ");
print(b >= a);
print(" ");
print(b == c);
print(" ");
local arr = [K(3), K(1), K(2)];
arr.sort();
local i = 0;
while (i < arr.len()) { print(arr[i].v); i = i + 1; }
print(" ");
return b > c;
