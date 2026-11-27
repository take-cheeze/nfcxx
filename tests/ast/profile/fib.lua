-- the profile of the tier (tests/ast/run.sh, docs/notes/profiler.md): fib is compiled at its first call and runs as native code
-- (21891 calls of fib(20) and no other compiled function, so one shared object writes the profile)
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(fib(20))
