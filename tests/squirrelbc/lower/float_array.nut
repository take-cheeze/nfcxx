// Floats in an array literal (APPENDARRAY of a float), in a table value, and as a call argument and result.
local a = [1.5, 2, -0.0, 0.25];
print(a[0]);
print(" ");
print(a[1]);
print(" ");
print(a[2]);
print(" ");
print(a.len());
print(" ");
local t = { half = 0.5, n = 2, quarter = 0.0 };
t.quarter = t.half / 2;
print(t.quarter);
print(" ");
print(t.half + t.n);
print(" ");
function scale(x, k) {
  return x * k;
}
print(scale(1.25, 4));
print(" ");
print(scale(3, 0.5));
print(" ");
return a[3] * 8;
