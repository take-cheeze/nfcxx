// A new field added to a class after an instance exists: the class is locked (SQClass::NewSlot, sqvm.cpp NewSlot).
class C { x = 1; }
local c = C();
C.q <- 2;
return 0;
