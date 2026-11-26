// print from a closure: the root table is the closure's this, so print is found through the root fallback.
function show(v) { print(v); }
show(5);
show("x");
return 9;
