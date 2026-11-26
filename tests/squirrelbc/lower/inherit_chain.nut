// A chain of three classes: each level's base.get() reaches the level above it (GETBASE of the closure, not of the instance).
class A { function get() { return 1; } }
class B extends A { function get() { return base.get() + 10; } }
class C extends B { function get() { return base.get() * 2; } }
local c = C();
print(c.get());
print(" ");
local b = B();
print(b.get());
print(" ");
return C().get() + 1;
