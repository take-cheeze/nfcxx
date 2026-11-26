// string.find: the index of the first occurrence from start (strstr), or null when there is none or start is past the end.
local s = "abcabc";
print(s.find("b")); print(" ");
print(s.find("b", 2)); print(" ");
print(s.find("zz")); print(" ");
print(s.find("")); print(" ");
print(s.find("c", 6)); print(" ");
print(s.find("a", 1.2)); print(" ");
return s.find("bc", 1);
