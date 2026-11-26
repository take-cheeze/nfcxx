// A derived class replaces a field's default (the base's field keeps its place in the instance), and adds a field of its own.
class A {
  x = 1;
  y = 10;
  function sum() { return x + y; }
}
class B extends A {
  x = 5;
  z = 100;
}
local a = A();
local b = B();
print(a.sum());
print(" ");
print(b.sum());
print(" ");
print(b.z);
print(" ");
b.x = 7;
print(b.sum());
print(" ");
return a.x;
