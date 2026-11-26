// Equality of strings: equal contents are equal (strings are interned), a string is not an integer, and a literal compares
// with a value built at run time.
local a = "ab";
local b = "a" + "b";
local r = 0;
if (a == b) r += 1;
if (a != "abc") r += 2;
if (a == "ab") r += 4;
if (b == 1) r += 8;
if (a != b) r += 16;
return r;
