-- Exercises strings, tables, closures, pcall/error (setjmp/longjmp) and string.format for run_lua.sh.
local t = {}
for i = 1, 10 do t[#t + 1] = i * i end
table.sort(t, function(a, b) return a > b end)
local s = table.concat(t, ",")
assert(s == "100,81,64,49,36,25,16,9,4,1", s)
assert(("hello"):upper():rep(2, "-") == "HELLO-HELLO")
assert(string.format("%5.2f|%d|%s|%x", 3.14159, 42, "x", 255) == " 3.14|42|x|ff")
assert(("a1b22c333"):gsub("%d+", "#") == "a#b#c#")
local words = {}
for w in ("the quick brown fox"):gmatch("%a+") do words[#words + 1] = w end
assert(#words == 4 and words[4] == "fox")
local ok, err = pcall(function() error("boom") end)
assert(not ok and err:find("boom"))
local ok2, err2 = pcall(function() local x = nil; return x.field end)
assert(not ok2 and err2:find("nil"))
assert(select(2, pcall(error, {code = 7})).code == 7)
local co = coroutine.wrap(function(a) local b = coroutine.yield(a + 1); return b * 2 end)
assert(co(1) == 2 and co(10) == 20)
local fib; fib = function(n) return n < 2 and n or fib(n - 1) + fib(n - 2) end
assert(fib(20) == 6765)
assert(math.maxinteger + 1 == math.mininteger and 7 // 2 == 3 and 2^10 == 1024.0)
print("lua-ok", #s, fib(20), _VERSION)
