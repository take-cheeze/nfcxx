// IsFalse of a float: 0.0 and -0.0 are false, any other float is true (sqvm.cpp IsFalse). NOT, JZ (if), AND and OR.
local z = 0.0;
local m = -0.0;
local f = 0.5;
if (z) print("z-true"); else print("z-false");
print(" ");
if (m) print("m-true"); else print("m-false");
print(" ");
if (f) print("f-true"); else print("f-false");
print(" ");
print(!z);
print(" ");
print(!m);
print(" ");
print(!f);
print(" ");
print(z && 3);
print(" ");
print(f && 3);
print(" ");
print(m || 7);
print(" ");
print(f || 7);
print(" ");
local n = 0;
while (f) {
  if (n >= 3) break;
  n = n + 1;
  f = f - 0.25;
}
print(n);
print(" ");
return f;
