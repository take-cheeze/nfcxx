// A comparison of an instance with an integer: the error names both types (Raise_CompareError).
class C { x = 1; }
local c = C();
return c < 1;
