-- Recursive calls: a function is inlined into its own call sites at most once (docs/notes/ast.md), so this measures what that buys;
-- with the tier on, fib is a numeric kernel and the recursion runs as native code.
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fib(32))
