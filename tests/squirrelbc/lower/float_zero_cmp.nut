// ObjCmp of two floats that are equal in value but not in bits: -0.0 and 0.0 are not the same value, so 0.0 <= -0.0 is
// false and 0.0 >= -0.0 is true (the reference orders them as 1).
local z = 0.0;
local m = -0.0 * 1.0;
return (z <= m ? 10 : 0) + (z >= m ? 1 : 0);
