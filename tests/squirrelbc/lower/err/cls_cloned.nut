// A clone of an instance: CLONE is not lowered (the _cloned metamethod is its hook).
class C { x = 1; function _cloned(o) { return 0; } }
local c = C();
local d = clone c;
return 1;
