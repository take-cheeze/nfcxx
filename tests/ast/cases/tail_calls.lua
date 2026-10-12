-- proper tail calls: constant stack, and the frame a tail call replaces is gone from error levels (docs/notes/ast.md, "Errors")
-- deep tail recursion runs in constant stack
local function loop(n, acc) if n == 0 then return acc end return loop(n - 1, acc + n) end
print(loop(100000, 0))
local function even(n) if n == 0 then return true end return odd(n - 1) end
function odd(n) if n == 0 then return false end return even(n - 1) end
print(even(10001))
local obj = {}
function obj:count(n) if n == 0 then return "done" end return self:count(n - 1) end
print(obj:count(50000))
local callable = setmetatable({}, {__call = function(self, n) if n == 0 then return "called" end return self(n - 1) end})
print(callable(30000))
-- multiple results pass through
local function three() return 1, 2, 3 end
local function pass() return three() end
print(pass())
print((pass()))
local function pass2(...) return select("#", ...), ... end
local function pass3(...) return pass2(...) end
print(pass3(nil, nil))
-- error levels count the frames a tail call replaced
local function lvl2(msg) error(msg, 2) end
local function viaTail() return lvl2("boom") end
local function viaCall() local r = lvl2("boom"); return r end
local function caller() return viaTail() end
print(pcall(caller))
print(pcall(function() return viaTail() end))
print(pcall(function() local x = viaTail(); return x end))
print(pcall(function() local x = viaCall(); return x end))
print(pcall(viaTail))
print(pcall(viaCall))
local function lvl3(msg) error(msg, 3) end
local function mid() return lvl3("deep") end
print(pcall(function() local y = mid(); return y end))
print(pcall(function() return mid() end))
local function top() local y = (function() return mid() end)(); return y end
print(pcall(top))
-- a tail call to a native keeps the caller (and its name in errors)
local function badrep() return string.rep() end
print(pcall(badrep))
local function errnative() return error("native level 2", 2) end
print(pcall(function() local z = errnative(); return z end))
print(pcall(function() return errnative() end))
-- calling something that cannot be called
print(pcall(function() return nothing() end))
print(pcall(function() local t = {} return t.x() end))
print(pcall(function() local t = {} return t:nope() end))
-- tail call with an object whose __call is a native
print(pcall(function() return setmetatable({}, {__call = error})("tc") end))
-- the arguments are evaluated before the callee runs
local trace = {}
local function note(x) trace[#trace + 1] = x; return x end
local function sink(a, b) return a + b end
local function tail2() return sink(note(1), note(2)) end
print(tail2(), table.concat(trace, ","))
-- varargs functions in tail position
local function va(...) local n = select("#", ...); if n > 3 then return n end return va(n, ...) end
print(va())
-- a tail call from inside loops and nested blocks
local function inloop(n) for i = 1, 3 do if i == 2 then return loop(n, 0) end end end
print(inloop(1000))
local function inwhile(n) while true do do return loop(n, 1) end end end
print(inwhile(1000))
-- upvalues of the replaced frame survive in closures
local function mk(n) local c = function() return n end; if n > 3 then return c end return mk(n + 1) end
print(mk(0)())
-- results of a tail-called function that errors later
local function thrower(n) if n == 0 then error("late") end return thrower(n - 1) end
print(pcall(thrower, 5000))
-- non-tail recursion still overflows
-- parenthesized call is not a tail call
local function paren(n) if n == 0 then return 0 end return (paren(n - 1)) end
print(pcall(paren, 100))
-- method tail call through a string
local function strm(s) return s:upper() end
print(strm("abc"))
-- a tail call where the callee frees the argument slots
local function shrink(a, b, c, d, e) return a end
local function grow() return shrink(1, 2, 3, 4, 5) end
print(grow())
