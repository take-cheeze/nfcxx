// The text of a float: its tostring() (the number delegate), and a concatenation with a string on either side (ToString).
local f = 1.5;
print(f.tostring());
print(" ");
print(f + "a");
print(" ");
print("a" + f);
print(" ");
print((0.25 * 4).tostring());
print(" ");
print(("x" + (1.0 / 3)));
print(" ");
print(-0.0);
print(" ");
return "v" + 2.5;
