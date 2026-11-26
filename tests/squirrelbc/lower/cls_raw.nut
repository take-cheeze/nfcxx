// rawin, rawget, rawset, getbase and getclass of a class and an instance (no metamethods, no user code).
class Base { x = 1; function f() { return 2; } }
class C extends Base { y = 5; constructor() { y = 6; } function g() { return 7; } }
local c = C();
print(C.rawin("y")); print(" ");
print(C.rawin("zz")); print(" ");
print(C.rawget("y")); print(" ");
print(C.rawget("g")()); print(" ");
print(C.getbase() == Base); print(" ");
print(Base.getbase()); print(" ");
print(c.rawin("x")); print(" ");
print(c.rawget("y")); print(" ");
print(c.rawget("f")()); print(" ");
print(c.getclass() == C); print(" ");
print(c.getclass().getbase() == Base); print(" ");
print(c.rawset("y", 9).y); print(" ");
print(c.rawin(null)); print(" ");
return c.rawget("x");
