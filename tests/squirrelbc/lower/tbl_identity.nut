// Tables compare by identity: a second name for the same table is equal, a new table is not.
local a = {};
local b = a;
local r = 0;
if (a == b) r += 1;
if (a != {}) r += 2;
b.x <- 9;
return r * 100 + a.x;
