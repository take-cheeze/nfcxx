// A table with a string key (by name and by brackets) and an integer key: NEWOBJ, NEWSLOT, GETK and GET.
local t = {};
t.x <- 5;
t["k"] <- 7;
t[3] <- 100;
local k = "k";
return t.x + t[k] + t[3];
