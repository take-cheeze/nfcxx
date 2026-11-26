// A float accumulated in a loop: the rounding of each float addition is the reference's (float, not double).
local s = 0.0;
local i = 0;
while (i < 10) {
  s = s + 0.1;
  i = i + 1;
}
print(s);
print(" ");
local k = 1.0;
local j = 0;
while (j < 5) {
  k = k * 1.5;
  j = j + 1;
}
return k;
