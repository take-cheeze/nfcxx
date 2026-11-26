// The number of comparisons of the heapsort: none for an array of one item, and a count fixed by the algorithm for more.
local calls = 0;
local cmp = function(x, y) { calls = calls + 1; return x - y; };
[7].sort(cmp);
local one = calls;
[9, 4, 6, 1, 3].sort(cmp);
local five = calls - one;
[].sort(cmp);
print(one); print(" ");
print(five); print(" ");
return calls;
