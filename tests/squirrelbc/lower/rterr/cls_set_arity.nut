// A _set with too few parameters: the metamethod is called with the key and the value (FallBackSet).
class S { function _set(k) { return k; } }
local s = S();
s.x = 1;
return 0;
