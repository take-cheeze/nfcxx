// A call whose result is not used (no target register), and a function that falls off its end (null, not used here), and a
// function that writes into a table it is given.
function set(t, k, v) { t[k] <- v; }
local t = {};
set(t, "a", 3);
set(t, "b", "x");
return t.a + t.b.len();
