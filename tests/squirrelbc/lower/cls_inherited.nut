// _inherited of a base class runs when a class extends it (CLASS_OP), with the new class as `this` and the class
// attributes as its parameter. A class extending that class takes the metamethod too, so it runs again.
class Base {
  function _inherited(attrs) { print("inherited "); }
}
class Derived extends Base { x = 2; }
class Second extends Derived { y = 3; }
local d = Derived();
local s = Second();
print(" ");
return d.x + s.y;
