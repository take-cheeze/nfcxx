// A string indexed by an integer is the integer code of the byte at that position; a negative index counts from the end.
local s = "abc";
return s[1] * 1000 + s[-1];
