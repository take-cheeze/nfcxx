// A call of an instance without a _call metamethod: the reference raises the error for the callee type (CALL).
class F { x = 1; }
local f = F();
return f(1);
