// An instance of a derived class locks the base class too (SQClass::Lock): a new field of the base is then refused.
class A { x = 1; }
class B extends A {}
local b = B();
A.q <- 2;
return 0;
