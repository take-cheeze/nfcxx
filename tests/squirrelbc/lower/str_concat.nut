// `+` on strings: the concatenation of two strings, and of a string with an integer, null and a boolean (ToString).
local s = "ab";
local t = s + "c";
local u = "n=" + 42 + ":" + null + ":" + true;
return t + "|" + u;
