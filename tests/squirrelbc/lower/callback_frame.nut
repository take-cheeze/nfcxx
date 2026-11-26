// The locals of a function that calls map, reduce and filter stay as they are when the callbacks return: a closure over
// a local of the caller is read and written through the callback.
local work = function(arr) {
  local bias = 100;
  local count = 0;
  local m = arr.map(function(v) { count = count + 1; return v + bias; });
  local f = arr.filter(function(i, v) { count = count + 1; return v > bias - 98; });
  bias = bias + count;
  return bias * 1000 + m[0] + f.len() * 10;
};
print(work([1, 2, 3])); print(" ");
local g = function(v) {
  local x = v * 2;
  local r = [x].reduce(function(acc, w) { return acc + w + x; }, 1);
  return r + x;
};
return g(5);
