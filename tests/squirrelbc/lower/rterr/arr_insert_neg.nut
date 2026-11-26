// a negative index is out of range for insert (it does not count from the end).
local a = [1];
a.insert(-1, 0);
return a.len();
