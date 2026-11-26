// A global read in a function (GET on `this`, which falls back to the root table) and a global written by it.
counter <- 0;
function bump(n) { counter = counter + n; return counter; }
bump(3);
bump(4);
return counter;
