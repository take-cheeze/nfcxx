// A static member is shared by the class: it is read through the class and through an instance, and an instance's field
// is its own. A field of a float value uses the float lowering.
class S {
  static k = 10;
  v = 2;
  w = 0.5;
  function f() { return v + 1; }
  function half() { return w / 2; }
}
print(S.k);
print(" ");
local s = S();
print(s.k);
print(" ");
print(s.f());
print(" ");
print(s.half());
print(" ");
return S().f() + s.v;
