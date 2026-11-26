// len of an array and of an empty array (NEWOBJ with no values).
local a = [5, 6, 7, 8];
local e = [];
return a.len() * 10 + e.len();
