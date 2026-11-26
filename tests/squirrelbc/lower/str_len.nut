// s.len() is a method call on a string: PREPCALLK on the string (the string delegate's len), then CALL with the string as
// the receiver.
local s = "hello";
local e = "";
return s.len() * 10 + e.len();
