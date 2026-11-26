// A % on an instance without _modulo: the error is only recorded (Raise_Error), the script goes on and the target keeps its
// value (the _OP_MOD rule of the notes).
class K { v = 1; }
local a = K();
local x = 1;
x = a % 2;
return x;
