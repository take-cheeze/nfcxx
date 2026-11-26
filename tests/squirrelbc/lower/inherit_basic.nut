// `extends`: the derived class has the base's members. base.get() in an overriding method calls the base's method with the
// instance as `this` (GETBASE), so the derived method adds to it.
class A {
  x = 1;
  function get() { return x; }
  function who() { return 10; }
}
class B extends A {
  y = 2;
  function get() { return base.get() + y; }
}
local b = B();
print(b.get());
print(" ");
print(b.x);
print(" ");
print(b.who());
print(" ");
return b.y;
