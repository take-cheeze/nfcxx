// A typeof of an instance: TYPEOF is not lowered, and its _typeof metamethod is not called here.
class T { function _typeof() { return "t"; } }
local t = T();
return typeof t;
