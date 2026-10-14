-- Tail calls of numeric kernels (docs/notes/ast.md, "Tiering"): a self tail call is a loop in compiled code, a deep one must give
-- the interpreter's answer, and an error inside a deep one must be the interpreter's error.

-- a million-deep self tail call, with an integer and then a float accumulator (two versions of one function)
local function loop(n, acc) if n == 0 then return acc end return loop(n - 1, acc + 1) end
print(loop(1000000, 0))
print(loop(300000, 0.5))

-- the arguments read the parameters they replace: a swap, and a rotation of three
local function swap(a, b, n) if n == 0 then return a * 10 + b end return swap(b, a, n - 1) end
print(swap(1, 2, 100001), swap(1, 2, 100000))
local function rot(a, b, c, n) if n == 0 then return a * 100 + b * 10 + c end return rot(b, c, a, n - 1) end
print(rot(1, 2, 3, 50000), rot(1, 2, 3, 50001))

-- a tail call that changes the type of an argument: the callee is another version, which then calls itself
local function grow(n, x) if n == 0 then return x end return grow(n - 1, x * 1.5) end
print(grow(10, 1), grow(10000, 1) > 0, grow(0, 2))
local function number(n, acc) if n == 0 then return acc end return number(n - 1, acc + 0.5) end
print(number(100000, 0), number(3, 1))

-- a tail call in a loop of the function, and one whose arguments are calls
local function scan(n, acc)
  local i = 0
  while true do
    i = i + 1
    if i > 3 then break end
  end
  if n == 0 then return acc end
  return scan(n - 1, acc + i)
end
print(scan(20000, 0))

local function step(x) return x * 3 % 1000003 end
local function walk(n, acc) if n == 0 then return acc end return walk(n - 1, step(acc) + n) end
print(walk(100000, 1))

-- depth: tail calls take no depth, non-tail calls do (the odd steps here: at most 1000 of them)
local function mix(n, acc)
  if n == 0 then return acc end
  if n % 2 == 0 then return mix(n - 1, acc + 1) end
  return 1 + mix(n - 1, acc)
end
print(mix(2000, 0))

-- a global function, and a tail call of the function through an upvalue of a closure made by a factory
function gl(n, acc) if n == 0 then return acc end return gl(n - 1, acc + 2) end
print(gl(50000, 0))
local function factory(k)
  local function f(n, acc) if n == 0 then return acc end return f(n - 1, acc + k) end
  return f
end
print(factory(3)(30000, 0), factory(0.5)(10, 0))

-- mutual tail recursion between kernels: a jump in the compiled code too, so a deep chain takes neither stack nor depth
local is_even, is_odd
function is_even(n) if n == 0 then return true end return is_odd(n - 1) end
function is_odd(n) if n == 0 then return false end return is_even(n - 1) end
print(is_even(100001), is_odd(100001))
local ping, pong
function ping(n, acc) if n == 0 then return acc end return pong(n - 1, acc + 1) end
function pong(n, acc) if n == 0 then return acc end return ping(n - 1, acc + 2) end
print(ping(1000000, 0), pong(999999, 0))
local ma, mb
function ma(n, z) if n == 0 then return n // z end return mb(n - 1, z) end
function mb(n, z) if n == 0 then return n // z end return ma(n - 1, z) end
print(pcall(ma, 30001, 0))
print(ma(30000, 7))

-- a loop of the main chunk that calls a tail recursion at every iteration (the loop may be taken over with the callee inside it)
local total = 0
for i = 1, 20 do total = total + loop(1000, i) end
print(total)

-- errors inside deep tail recursions: the message, the position and the value are the interpreter's
local function divz(n, acc) if n == 0 then return acc // n end return divz(n - 1, acc + 1) end
print(pcall(divz, 30000, 0))
local function argerr(n, acc) if n == 5 then return acc // (n - 5) end return argerr(n - 1, acc // 1 + n) end
print(pcall(argerr, 20000, 7))
local function deepfloat(n, acc) if n == 0 then return (acc + 0.5) | 1 end return deepfloat(n - 1, acc + 0.25) end
print(pcall(deepfloat, 15000, 0))
print(select("#", pcall(loop, 200000, 0)), (pcall(loop, 10, 0)))
