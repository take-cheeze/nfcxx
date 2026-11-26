// A foreach over an instance: FOREACH is not lowered (the _nexti metamethod is its iterator).
class I { function _nexti(p) { return null; } }
local i = I();
local n = 0;
foreach (k, v in i) { n = n + 1; }
return n;
