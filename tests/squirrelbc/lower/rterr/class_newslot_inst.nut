// The new slot operator on an instance: an instance does not take one (NewSlot, sqvm.cpp).
class C { x = 1; }
local c = C();
c.z <- 2;
return 0;
