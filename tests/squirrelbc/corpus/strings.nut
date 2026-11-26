// String literals, concatenation, and a string with embedded bytes.
local s = "hello"
local t = s + ", world\n\t\"quoted\" \\ end"
local u = "caf\xc3\xa9"
local n = t.len() + u.len()
return n
