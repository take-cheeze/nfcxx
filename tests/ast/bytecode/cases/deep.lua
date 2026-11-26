-- Deep recursion through bytecode frames: 1400 nested calls (each a call in the middle of an expression) must return, and an
-- infinite one must end as a script error ("stack overflow"), not as a crash of the C++ stack.
local function f(n) if n == 0 then return 0 end return 1 + f(n - 1) end
print(f(1400))
local function g() return 1 + g() end
local ok, e = pcall(g)
print(ok, string.find(e, "stack overflow") ~= nil)
