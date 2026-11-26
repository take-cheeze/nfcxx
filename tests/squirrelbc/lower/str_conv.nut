// tointeger (with a base) and tofloat of a string: a leading number, a float when the text has a point or an exponent.
local s = "12";
print(s.tointeger()); print(" ");
print("ff".tointeger(16)); print(" ");
print("1.5".tofloat()); print(" ");
print("12abc".tointeger()); print(" ");
print("3.5".tointeger()); print(" ");
print("1e2".tofloat()); print(" ");
print("  42".tointeger()); print(" ");
return s.tointeger() + 1;
