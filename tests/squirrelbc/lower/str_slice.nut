// string.slice: a new string of the bytes from start up to end; a negative index counts from the end, a float truncates.
local s = "hello world";
print(s.slice(0, 5)); print(" ");
print(s.slice(6)); print(" ");
print(s.slice(-5)); print(" ");
print(s.slice(2, -3)); print(" ");
print(s.slice(1.5, 4.9)); print(" ");
print(s.slice(3, 3).len()); print(" ");
return s.slice(0, 1) + s.slice(-1);
