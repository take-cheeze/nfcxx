// apply with a five-parameter callback: the same error, from the apply.
local a = [1, 2];
a.apply(function(p, b, c, d, e) { return b; });
return a[0];
