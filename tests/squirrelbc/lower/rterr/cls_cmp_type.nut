// _cmp must return an integer: the comparison of two instances whose _cmp returns a string is an error (ObjCmp).
class K { function _cmp(o) { return "big"; } }
local a = K();
local b = K();
return a < b;
