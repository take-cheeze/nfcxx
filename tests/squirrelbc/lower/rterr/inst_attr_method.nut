// getattributes is a class method: an instance has no such method (the index error).
class K { x = 1; }
local k = K();
return k.getattributes("x");
