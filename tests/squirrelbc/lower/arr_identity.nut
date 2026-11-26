// Arrays compare by identity: an array equals itself and not another array with the same values.
local a = [1];
local b = [1];
local c = a;
return (a == b ? 10 : 0) + (a == c ? 1 : 0);
