// string.tolower and toupper: the whole string is the result, with only the bytes from start up to end converted.
local s = "Hello World";
print(s.tolower()); print(" ");
print(s.toupper()); print(" ");
print(s.tolower(0, 5)); print(" ");
print(s.toupper(6)); print(" ");
print(s.toupper(2, 4)); print(" ");
return s.tolower(-5);
