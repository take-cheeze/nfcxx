// rawget of a key the instance does not have.
class K { function m() { return 1; } }
local k = K();
return k.rawget("nope");
