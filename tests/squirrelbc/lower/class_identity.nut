// Instances compare by identity: the same instance is equal to itself, and two instances of one class are not equal. An
// empty class has no members; its instances still differ.
class E {}
local a = E();
local b = E();
local c = a;
print(a == c);
print(" ");
print(a == b);
print(" ");
print(a != b);
print(" ");
print(c != a);
print(" ");
return a == null;
