// A class without a constructor: each instance starts with the class's field defaults, the instances are independent, and
// the arguments of the call are not used (there is no constructor to take them).
class P {
  n = 3;
  tag = "p";
  function show() { return n * 2; }
}
local a = P();
local b = P(1, 2, 3);
print(a.n);
print(" ");
print(b.tag);
print(" ");
a.n = 7;
print(b.n);
print(" ");
print(a.show());
print(" ");
return b.show();
