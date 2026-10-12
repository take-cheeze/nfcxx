-- Small functions that read and write variables of the functions around them (upvalues): counters, shared state between several
-- closures, the loop variable of the loop that made the closure, upvalues of upvalues, and the caller changing a variable
-- between two calls of an inlined getter.
print("-- a counter and a setting, written and read by small closures")
local count = 0
local base = 100
local function tick() count = count + 1; return count end
local function addbase(x) return x + base end
local function setbase(v) base = v end
for i = 1, 8 do
  setbase(100 + i)
  print(tick(), addbase(i), count, base)
end

print("-- several closures share one variable")
local function make_counter(step)
  local n = 0
  local function inc() n = n + step; return n end
  local function get() return n end
  local function reset() n = 0 end
  return inc, get, reset
end
local inc1, get1, reset1 = make_counter(1)
local inc5, get5, reset5 = make_counter(5)
for i = 1, 6 do
  inc1(); inc5(); inc5()
  print(i, get1(), get5(), inc1(), get5())
end
reset5()
for i = 1, 4 do print(get1(), get5(), inc5()) end

print("-- closures made in a loop: one function, a different variable in each")
local getters, setters = {}, {}
for i = 1, 4 do
  local v = i * 10
  getters[i] = function() return v + i end
  setters[i] = function(x) v = x end
end
for round = 1, 4 do
  local s = {}
  for k = 1, 4 do s[#s + 1] = getters[k]() end
  print(table.concat(s, " "))
  for k = 1, 4 do setters[k](round * k) end
end

print("-- upvalues of upvalues")
local function outer(a)
  local b = a * 2
  local function middle(c)
    local function inner(d) return a + b + c + d end
    return inner(1) + inner(2)
  end
  local function readonly() return a + b end
  return middle, readonly
end
local m1, r1 = outer(1)
local m2, r2 = outer(10)
for i = 1, 6 do print(m1(i), m2(i), r1(), r2()) end

print("-- the caller changes a variable between two calls of an inlined reader")
local state = "a"
local function read() return state end
for i = 1, 6 do
  local before = read()
  state = state .. i
  print(before, read(), #state)
end

print("-- an upvalue that holds a function, replaced")
local op = function(x) return x + 1 end
local function apply(x) return op(x) end
for i = 1, 6 do
  if i == 4 then op = function(x) return x * 100 end end
  print(apply(i))
end

print("-- the upvalue is a table that the callee updates")
local stats = {n = 0, sum = 0}
local function record(x) stats.n = stats.n + 1; stats.sum = stats.sum + x; return stats.n end
for i = 1, 8 do record(i * i) end
print(stats.n, stats.sum, record(0), stats.sum / stats.n)

print("-- a read-only upvalue declared <const>, and one that is nil")
local K <const> = 42
local nothing = nil
local function usek(x) return x + K end
local function usenil(x) return nothing == nil, x end
for i = 1, 6 do print(usek(i), usenil(i)) end
nothing = 1
print(usenil(0))
