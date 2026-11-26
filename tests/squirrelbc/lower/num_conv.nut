// tofloat, tointeger and tochar of an integer, a float and a boolean (the number delegate, which the boolean takes too).
local i = 7;
local f = 2.75;
print(i.tofloat()); print(" ");
print(f.tofloat()); print(" ");
print((true).tofloat()); print(" ");
print(f.tointeger()); print(" ");
print((-3.9).tointeger()); print(" ");
print((false).tointeger()); print(" ");
print((65).tochar()); print(" ");
print((321).tochar().len()); print(" ");
print((true).tochar().len()); print(" ");
return i.tointeger() + (200).tochar()[0];
