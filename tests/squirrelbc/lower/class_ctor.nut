// A class with a constructor, a field and a method: calling the class makes the instance, and the constructor runs with it
// as `this`. The field is read and assigned through the instance (GET and SET on an instance).
class C {
  x = 1;
  constructor(a) { x = a; }
  function get() { return x; }
}
local c = C(5);
print(c.get());
print(" ");
c.x = 9;
print(c.get());
print(" ");
return c.x + 1;
