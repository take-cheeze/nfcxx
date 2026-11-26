// A field that the class does not have, read through an instance: the index error (Raise_IdxError).
class C { x = 1; }
local c = C();
return c.nope;
