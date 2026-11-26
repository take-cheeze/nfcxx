// A loop over a literal array, its length read at each step.
local a = [3, 1, 4, 1, 5];
local s = 0;
for (local i = 0; i < a.len(); i = i + 1) { s = s + a[i]; }
return s;
