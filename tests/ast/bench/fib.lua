-- Recursive calls: a function is inlined into its own call sites at most once (docs/notes/ast.md), so this measures what that buys.
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fib(32))
