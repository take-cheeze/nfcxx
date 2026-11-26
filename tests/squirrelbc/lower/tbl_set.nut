// SET on an existing key replaces the value; a table literal with slots; a string value read back.
local t = { a = 1, b = "bob" };
t.a = 10;
t["b"] = t.b + "by";
return t.a + t.b.len() * 100;
