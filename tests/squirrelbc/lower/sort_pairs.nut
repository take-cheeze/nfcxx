// array.sort by one key: the items are arrays [key, tag], compared by the key only, so the order of the equal keys is the
// heapsort's and is printed as the tags come out.
local pairs = [[2, "a"], [1, "b"], [2, "c"], [0, "d"], [1, "e"], [2, "f"], [1, "g"], [0, "h"], [2, "i"]];
pairs.sort(function(x, y) { return x[0] - y[0]; });
local i = 0;
while (i < pairs.len()) { print(pairs[i][1]); i = i + 1; }
print(" ");
local k = [[1, "p"], [1, "q"], [1, "r"], [1, "s"]];
k.sort(function(x, y) { return 0; });
local j = 0;
while (j < k.len()) { print(k[j][1]); j = j + 1; }
return pairs.len();
