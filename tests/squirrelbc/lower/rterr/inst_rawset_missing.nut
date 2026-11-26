// rawset of a key that is not a field of the instance.
class K { x = 1; }
local k = K();
return k.rawset("zz", 9);
