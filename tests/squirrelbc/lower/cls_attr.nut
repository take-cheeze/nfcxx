// Class attributes (CLASS_OP) and member attributes (NEWSLOTA): read, replace (the old value comes back), and copied into a
// derived class; a member without attributes has null.
class Base </ kind = 4, label = 2 /> { x = 1; </ tag = 5 /> y = 3; </ tag = 6 /> function f() { return 2; } }
class C extends Base </ z = 9 /> { </ w = 8 /> function g() { return 7; } }
local c = C();
print(C.getattributes(null).z); print(" ");
print(Base.getattributes(null).kind); print(" ");
print(C.getattributes("g").w); print(" ");
print(C.getattributes("f").tag); print(" ");
print(C.getattributes("y").tag); print(" ");
print(C.getattributes("x") == null); print(" ");
print(C.setattributes("g", {w = 1}).w); print(" ");
print(C.getattributes("g").w); print(" ");
print(C.setattributes(null, {z = 10}).z); print(" ");
print(C.getattributes(null).z); print(" ");
print(Base.getattributes("f").tag); print(" ");
return c.x;
