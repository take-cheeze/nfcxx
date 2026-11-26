// A four-parameter callback on the second item: the first call printed its item, then the call of the second item reads
// the array as its callee (the first call consumed the copy of the callback), so the error is attempt to call array.
local a = [5, 6];
local r = a.map(function(p, b, c, d) { print(b); print(" "); return b + c; });
return r.len();
