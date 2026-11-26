// A delete of an instance member: DELETE is not lowered (the _delslot metamethod is its hook).
class D { x = 1; function _delslot(k) { return 1; } }
local d = D();
delete d.x;
return 1;
