// A static member of the base is the derived class's too, and a static of the derived class is its own.
class A {
  static s = 7;
  function f() { return 2; }
}
class B extends A {
  static t = 3;
}
print(B.s);
print(" ");
print(B.t);
print(" ");
print(A.s + B.t);
print(" ");
return B().f();
