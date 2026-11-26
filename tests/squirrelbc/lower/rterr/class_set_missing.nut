// Assigning a name the class does not have through an instance: an instance takes only its fields (sqvm.cpp Set).
class C { x = 1; }
local c = C();
c.nope = 2;
return 0;
