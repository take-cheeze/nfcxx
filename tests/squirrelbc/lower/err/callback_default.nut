// A callback with a default parameter is a nested function with default parameters, which the producer still refuses.
local a = [1, 2];
return a.map(function(v, d = 2) { return v + d; }).len();
