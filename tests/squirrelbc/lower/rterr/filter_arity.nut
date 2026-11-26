// filter calls its function with three values (this, the index, the item): a function of one parameter is a count error.
local a = [1, 2, 3];
return a.filter(function(v) { return true; }).len();
