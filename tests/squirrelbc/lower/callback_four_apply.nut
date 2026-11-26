// apply with a four-parameter callback on a one-item array: the item is replaced by the callback's result.
local a = [5];
a.apply(function(p, b, c, d) { return b * 10 + c; });
return a[0];
