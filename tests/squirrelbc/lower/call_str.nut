// A function that takes and returns strings, and a method call on a string receiver inside a function.
function greet(s) { return "hi " + s + "!" + s.len(); }
local name = "bob";
return greet(name) + "/" + greet("x");
