// apply with a six-parameter callback: the same read below the apply's frame as map (nargs 7).
local a = [1, 2];
a.apply(function(p, b, c, d, e, f) { return b; });
return a.len();
