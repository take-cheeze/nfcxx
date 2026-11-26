// Callbacks that call back: a reduce inside a map, a sort inside a reduce, a recursive function passed to map, and a
// callback that changes a variable of the caller. The frames of the calls stay separate.
local total = 0;
local grid = [[1, 2], [3, 4], [5]];
local sums = grid.map(function(row) {
  return row.reduce(function(acc, v) { total = total + 1; return acc + v; }, 0);
});
print(sums[0] + sums[1] + sums[2]); print(" ");
print(total); print(" ");
local fib = null;
fib = function(n) { return n < 2 ? n : fib(n - 1) + fib(n - 2); };
local fibs = [1, 5, 10].map(function(v) { return fib(v); });
print(fibs[2]); print(" ");
local last = [3, 1, 2].reduce(function(acc, v) {
  local copy = [acc, v, 9, 4].sort(function(x, y) { return x - y; });
  return copy[0] * 100 + copy[3];
});
print(last); print(" ");
return total;
