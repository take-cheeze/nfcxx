-- two compiled units in one run (tests/ast/run.sh): tri and fib are each compiled at their first call, so each has its own
-- shared object. The profile must hold the records of both (2 sites: tri makes 11 calls, fib(20) makes 21891)
local function tri(n) if n == 0 then return 0 end return n + tri(n - 1) end
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
print(tri(10))
print(fib(20))
