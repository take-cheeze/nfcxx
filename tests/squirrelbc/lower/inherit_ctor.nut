// The constructor of the base is the derived class's when the derived class has none; a derived constructor calls the base's
// with base.constructor(...), and it runs with the instance as `this`.
class A {
  v = 0;
  constructor(n) { v = n; }
}
class B extends A {}
class C extends A {
  constructor(n) { base.constructor(n * 2); }
}
local b = B(3);
print(b.v);
print(" ");
local c = C(4);
print(c.v);
print(" ");
return B(7).v + C(1).v;
