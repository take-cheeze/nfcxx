// Equality of floats: by value, a float and an integer are equal when they are the same number (IsEqual, sqvm.cpp),
// -0.0 is equal to 0.0, and a float is never equal to a boolean or null.
local f = 1.5;
local g = 1.5;
local z = 0.0;
local m = -0.0;
local i = 1;
print(f == g);
print(f != g);
print(f == 1.5);
print(f != 2.5);
print(z == m);
print(z != m);
print(1.0 == i);
print(2.0 == i);
print(i != 1.0);
print(f == null);
print(f != true);
print(null == z);
print(f == "1.5");
return f == 1.5;
