// tostring as a method of an integer, a boolean, a string and a negative literal (the number and string delegates).
local i = 12;
local b = true;
local s = "hi";
print(i.tostring());
print(b.tostring());
print(s.tostring());
print((false).tostring());
return (-3).tostring();
