// An instance is not callable: the call error names its type.
class C { x = 1; }
local c = C();
return c();
