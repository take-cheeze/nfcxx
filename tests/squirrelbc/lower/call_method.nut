// A function stored in a table and called with a receiver: PREPCALLK on the table sets `this` to the table.
local obj = {};
obj.v <- 40;
obj.get <- function(d) { return d + 2; };
return obj.get(1);
