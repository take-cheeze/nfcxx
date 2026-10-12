-- Numeric kernels. With the tier on (tests/ast/run.sh runs every program in this directory that way too, compiling each function at
-- its first call) the functions below run as native code, the ones that are not kernels stay in the interpreter; the output must be
-- Lua's either way, down to integer wraparound, float versus integer results and error messages.
local function show(...) print(...) end

-- recursion, mutual recursion, kernels calling kernels (through upvalues and through globals)
local function fib(n) if n < 2 then return n end return fib(n - 1) + fib(n - 2) end
show(fib(0), fib(1), fib(2), fib(15), fib(24), fib(10.0), fib(5, "extra", {}))
local function sumto(n) if n == 0 then return 0 end return n + sumto(n - 1) end
show(sumto(10), sumto(1000))
local iseven
local function isodd(n) if n == 0 then return false end return iseven(n - 1) end
function iseven(n) if n == 0 then return true end return isodd(n - 1) end
show(isodd(7), iseven(7), isodd(10), iseven(10), iseven(0))
function gsum(a, b) return a + b end
function gtwice(x) return gsum(x, x) end
show(gtwice(21), gtwice(1.5), gtwice(math.maxinteger))
local function sq(x) return x * x end
local function addsq(a, b) return sq(a) + sq(b) end
local function nest(a, b, c) return addsq(sq(a), addsq(b, c)) end
show(nest(1, 2, 3), nest(2, 1.5, 3), nest(10, 10, 10))

-- while, repeat, numeric for with every kind of bound, break, early return
local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
show(gcd(48, 18), gcd(17, 5), gcd(1071, 462), gcd(0, 5), gcd(-12, 18), gcd(12.0, 18))
local function collatz(n) local s = 0 while n ~= 1 do if n % 2 == 0 then n = n // 2 else n = 3 * n + 1 end s = s + 1 end return s end
show(collatz(1), collatz(27), collatz(97), collatz(871))
local function digits(n) local c = 0 repeat c = c + 1 n = n // 10 until n == 0 return c end
show(digits(0), digits(9), digits(10), digits(123456789), digits(math.maxinteger))
local function forsum(a, b, c) local s = 0 for i = a, b, c do s = s + i end return s end
show(forsum(1, 10, 1), forsum(10, 1, -1), forsum(1, 10, 3), forsum(10, 1, -3), forsum(1, 0, 1), forsum(5, 5, 1))
show(forsum(1, 3.5, 1), forsum(3, 1.2, -1), forsum(1.0, 3, 1), forsum(1, 2, 0.5), forsum(0.1, 1, 0.3))
show(forsum(math.maxinteger - 2, math.maxinteger, 1), forsum(math.mininteger, math.mininteger + 2, 1))
show(forsum(1, -math.huge, 1), forsum(1, 0 / 0, 1), forsum(math.maxinteger, math.huge, math.maxinteger), forsum(math.mininteger, -math.huge, -1))
show(pcall(forsum, 1, 5, 0))
local function loopvar(n) local acc = 0 for i = 1, n do local j = i i = i * 10 acc = acc + j + i end return acc end
show(loopvar(5), loopvar(0))
local function nested(n) local c = 0 for i = 1, n do for j = 1, n do if i * j > n then break end c = c + 1 end end return c end
show(nested(10), nested(30))
local function first_square_over(n) for i = 1, n do if i * i > n then return i end end return -1 end
show(first_square_over(50), first_square_over(0))
local function spin(n) local i = 0 while true do i = i + 1 if i >= n then return i end end end
show(spin(5), spin(1))

-- integer wraparound
local function mulw(a, b) return a * b end
show(mulw(math.maxinteger, 2), mulw(math.mininteger, -1), mulw(3037000500, 3037000500), mulw(1 << 62, 4), mulw(2, 0.5))
local function addw(a, b) return a + b end
show(addw(math.maxinteger, 1), addw(math.mininteger, -1), addw(math.maxinteger, 1.0))
local function subw(a, b) return a - b end
show(subw(math.mininteger, 1), subw(0, math.mininteger))
local function negw(a) return -a end
show(negw(math.mininteger), negw(5), negw(2.5), negw(0.0))
local function sumsq(n) local s = 0 for i = 1, n do s = s + i * i end return s end
show(sumsq(100), sumsq(100000))
local function overflow_loop(n) local s = math.maxinteger - 5 for i = 1, n do s = s + 1 end return s end
show(overflow_loop(3), overflow_loop(10))

-- bitwise operators and shifts
local function hash(n) local h = 5381 for i = 1, n do h = ((h << 5) + h + i) & 0xffffffff end return h end
show(hash(10), hash(1000))
local function popcount(x) local c = 0 while x ~= 0 do c = c + (x & 1) x = x >> 1 end return c end
show(popcount(255), popcount(-1), popcount(0x5555555555555555), popcount(math.mininteger))
local function shl(x, n) return x << n end
local function shr(x, n) return x >> n end
show(shl(1, 62), shl(1, 63), shl(1, 64), shl(1, -1), shl(-1, 1), shr(-1, 1), shr(-1, 63), shr(-1, 64), shr(1, -62), shr(256, 4))
local function bxor(a, b) return a ~ b end
local function bnot(a) return ~a end
show(bxor(5, 3), bnot(5), bnot(-1), bxor(math.maxinteger, math.mininteger))
show(shl(1.0, 2), shl(3, 1.0), pcall(shl, 1.5, 1))

-- float versus integer: results, division, modulo, power
local function div(a, b) return a / b end
local function idiv(a, b) return a // b end
local function mod(a, b) return a % b end
local function pow(a, b) return a ^ b end
show(div(7, 2), div(6, 3), div(-1, 0), div(0, 0) ~= div(0, 0), div(1, 3.0))
show(idiv(7, 2), idiv(-7, 2), idiv(7, -2), idiv(-7, -2), idiv(7.0, 2), idiv(-7.5, 2), idiv(7, 0.0), idiv(-7, 0.0), idiv(math.mininteger, -1), idiv(math.maxinteger, -1))
show(mod(7, 3), mod(-7, 3), mod(7, -3), mod(-7, -3), mod(7.5, 2), mod(-7.5, 2), mod(7, -2.5), mod(math.mininteger, -1), mod(5, math.huge), mod(-5, math.huge), mod(5, -math.huge))
show(pow(2, 10), pow(2, 0.5), pow(2, -1), pow(-8, 1 / 3) ~= pow(-8, 1 / 3), pow(0, 0), pow(2.5, 2), pow(10, 15))

-- comparisons between integers and floats, equality, booleans
local function lt(a, b) return a < b end
local function le(a, b) return a <= b end
local function gt(a, b) return a > b end
local function ge(a, b) return a >= b end
local function eq(a, b) return a == b end
local function ne(a, b) return a ~= b end
show(lt(1, 2), lt(2, 1), lt(1.5, 2), lt(1, 1.5), lt(2 ^ 53, 2 ^ 53 + 1), lt(9007199254740993, 9007199254740992.0))
show(le(1, 1.0), le(9007199254740993, 9007199254740992.0), ge(9007199254740993, 9007199254740992.0), gt(math.maxinteger, 2 ^ 63), lt(math.maxinteger, 2 ^ 63), le(math.mininteger, -2 ^ 63), lt(math.mininteger, -2 ^ 63))
show(gt(1, 0.5), gt(0.5, 1), ge(2, 2.0), ge(2.0, 3), lt(0 / 0, 1), gt(0 / 0, 1), le(1, 0 / 0), ge(1, 0 / 0))
show(eq(1, 1.0), eq(2 ^ 53, 2 ^ 53 + 1), eq(math.maxinteger, math.maxinteger + 0.0), ne(1, 2), ne(0 / 0, 0 / 0), eq(0 / 0, 0 / 0), eq(true, true), eq(true, false))
local function logic(a, b, c) if a < b and b < c or a == c then return 1 elseif not (a < c) then return 2 end return 3 end
show(logic(1, 2, 3), logic(3, 2, 1), logic(1, 3, 2), logic(2, 2, 2))
local function between(x, lo, hi) return x >= lo and x <= hi end
show(between(5, 1, 10), between(0, 1, 10), between(5.5, 1, 10))
local function flag(f, x) if f then return x + 1 end return x - 1 end
show(flag(true, 1), flag(false, 1), flag(true, 1.5))
local function notnot(x) return not not x end
show(notnot(1), notnot(0), notnot(false), notnot(true))
local function sel(c, a, b) if c then return a else return b end end
show(sel(true, 1, 2), sel(false, 1, 2), sel(true, 1.5, 2))

-- floating point: Mandelbrot, numeric integration with a numeric upvalue that changes type
local function mandel(cx, cy, maxit)
  local x, y, i = 0.0, 0.0, 0
  while i < maxit and x * x + y * y <= 4.0 do x, y = x * x - y * y + cx, 2.0 * x * y + cy i = i + 1 end
  return i
end
local row = {} for k = -10, 10 do row[#row + 1] = mandel(k / 10, 0.3, 50) end show(table.concat(row, " "))
show(mandel(0, 0, 10), mandel(1, 1, 10), mandel(-2.0, 0, 100))
local scale = 0.5
local function f(x) return scale * x * x + 1.0 / (1.0 + x) end
local function integrate(a, b, n) local h = (b - a) / n local s = 0.0 for i = 0, n - 1 do s = s + f(a + (i + 0.5) * h) end return s * h end
show(string.format("%.9f", integrate(0.0, 3.0, 1000)))
scale = 2
show(string.format("%.9f", integrate(0.0, 3.0, 1000)))
scale = 0.25
show(string.format("%.9f", integrate(0.0, 3.0, 1000)))
local function newton(v) local g = v / 2 for _ = 1, 20 do g = (g + v / g) / 2 end return g end
show(string.format("%.10f %.10f", newton(2), newton(144)), newton(0.0) ~= newton(0.0))

-- a function that is rebound after it was called is not the function the compiled code assumed
local function inc(x) return x + 1 end
local function twice(x) return inc(inc(x)) end
show(twice(1), twice(5), twice(1.5))
inc = function(x) return x + 10 end
show(twice(1), twice(5), twice(1.5))
inc = function(x) return x * x end
show(twice(1), twice(5), twice(1.5))
local function make(k) return function(x) return x * k end end
local m2, m3 = make(2), make(3)
local cur = m2
local function callcur(x) return cur(x) end
show(callcur(10), callcur(20))
cur = m3
show(callcur(10), callcur(20))
cur = make(1.5)
show(callcur(10), callcur(2))
cur = print
show(pcall(callcur, 1))

-- division and modulo by zero: the same error, at the same line
local function d0(a, b) return a // b end
local function m0(a, b) return a % b end
show(d0(7, 2), pcall(d0, 7, 0), pcall(d0, 7.0, 0))
show(m0(7, 2), pcall(m0, 7, 0), pcall(m0, 7.5, 0))
local function chain(n) local s = 0 for i = 1, n do s = s + 100 // (5 - i) end return s end
show(pcall(chain, 4), pcall(chain, 5), pcall(chain, 6))
local function viacall(a, b) return sq(d0(a, b)) end
show(viacall(9, 3), pcall(viacall, 9, 0))

-- shapes that are not kernels run as before; so do wrong arguments
local function conflict(n) local x = 0 for i = 1, n do x = x + 0.5 end return x end
show(conflict(4), conflict(0))
local function retmix(n) if n > 0 then return n end return 0.5 end
show(retmix(3), retmix(-1), math.type(retmix(3)), math.type(retmix(-1)))
local function noret(n) local s = 0 for i = 1, n do s = s + i end end
show(noret(5), (noret(5)))
local function two(a, b) return a + b, a - b end
show(two(5, 3))
local function tostr(n) return tostring(n) .. "!" end
show(tostr(5), tostr(1.5))
local function sideeffect(n) counter = (counter or 0) + n return counter end
show(sideeffect(1), sideeffect(2))
show(pcall(fib), pcall(fib, "5"), pcall(fib, {}), pcall(sq, nil))

-- kernels called from native code (a comparator, pcall) and used as values
local t = {5, 2, 8, 1, 9, 3, 7}
table.sort(t, function(a, b) return a > b end)
show(table.concat(t, " "))
local function cmp(a, b) return a < b end
table.sort(t, cmp)
show(table.concat(t, " "), cmp(1, 2), select("#", cmp(1, 2)))
local fs = {sq, nest, fib}
show(fs[1](7), fs[2](1, 2, 3), fs[3](10))
