// Unary minus of an instance without _unm: the error names the type (NEG_OP).
class K { v = 1; }
local a = K();
return -a;
