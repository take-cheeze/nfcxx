-- A call site that was inlined for one function and meets another: it gives the clone up, may be inlined again for the new
-- function a few times, and in the end is a plain call. Whatever the pattern, the results and the errors are those of real calls.
local function try(f, ...)
  local r = table.pack(pcall(f, ...))
  for i = 1, r.n do r[i] = tostring(r[i]) end
  print(table.concat(r, " "))
end

local function A(x) return x + 1 end
local function B(x) return x * 2 end
local function Cc(x) return x - 3 end
local function D(x, y) local s = 0 for i = 1, x do s = s + i end return s end
local fns = {A, B, Cc, D}

local function site(f, v) return f(v) end
print("-- long runs of one function, then another, over and over")
for round = 1, 8 do
  local acc = 0
  for k = 1, #fns do
    for i = 1, 6 do acc = acc + site(fns[k], i) end
  end
  print(round, acc)
end

print("-- alternating at every call")
local acc = 0
for i = 1, 60 do acc = acc + site(fns[i % 4 + 1], i) end
print(acc)
acc = 0
for i = 1, 60 do acc = acc + site(i % 2 == 0 and A or B, i) end
print(acc)

print("-- a native, nil and a table with __call in between")
local callable = setmetatable({}, {__call = function(self, x) return -x end})
local mix = {A, A, A, math.abs, A, A, A, callable, A, A, A, B, B, B, B, Cc, Cc, Cc, B, B, B}
for rep = 1, 3 do
  local s = 0
  for i = 1, #mix do s = s + site(mix[i], i) end
  print(rep, s)
end
mix[5] = nil
for i = 1, 4 do try(function() local s = 0 for k = 1, 8 do s = s + site(mix[k], k) end return s end) end

print("-- methods whose implementation changes under the site")
local K = {}
K.__index = K
function K:v() return self.n end
local k1 = setmetatable({n = 1}, K)
local function callv(o) return o:v() end
for round = 1, 6 do
  local s = 0
  for i = 1, 6 do s = s + callv(k1) end
  print(round, s)
  if round == 2 then function K:v() return self.n * 10 end end
  if round == 3 then k1.v = function(self) return -1 end end
  if round == 4 then k1.v = nil; function K:v() return self.n + 100 end end
  if round == 5 then K.v = nil; k1.n = nil; try(callv, k1); function K:v() return self.n end; try(callv, k1); k1.n = 5 end
end

print("-- methods with arguments (substituted) whose implementation changes under the site")
local W = {}
W.__index = W
function W:w(x, y) return self.n + x + y end
local w1 = setmetatable({n = 1}, W)
local function callw(o, a) return o:w(a, 2) end
for round = 1, 6 do
  local s = 0
  for i = 1, 6 do s = s + callw(w1, i) end
  print(round, s)
  if round == 1 then w1.w = function(self, x, y) return x * y end end
  if round == 2 then w1.w = nil; function W:w(x, y) return x - y end end
  if round == 3 then w1.w = function(self, x) return x end end
  if round == 4 then w1.w = function(self, x, y) return y end end
  if round == 5 then w1.w = nil end
end

print("-- extra arguments that are not evaluated by one callee and used by the next")
local function xsite(f, a) local k = 5 return f(a, 2, k, "s") end
local xs = {function(x) return x end, function(x, y) return x + y end, function(x, y, z) return x + y + z end,
            function(x, y, z, w) return w .. z .. y .. x end, function() return "none" end}
for round = 1, 3 do
  for k = 1, #xs do
    local out = {}
    for i = 1, 5 do out[#out + 1] = tostring(xsite(xs[k], i)) end
    print(round, k, table.concat(out, ","))
  end
end
local X1, X2 = {}, {}
X1.__index = X1
X2.__index = X2
function X1:m(x) return x end
function X2:m(x, y, z) return x .. y .. z end
local xos = {setmetatable({}, X1), setmetatable({}, X2)}
local function xmsite(o, a) return o:m(a, 2, "z") end
for round = 1, 4 do
  local out = {}
  for k = 1, 2 do
    for i = 1, 4 do out[#out + 1] = tostring(xmsite(xos[k], i)) end
  end
  print(round, table.concat(out, ","))
end

print("-- errors raised by the function the site meets")
local function f1(x) return x.a end
local function f2(x) return x + 1 end
local function f3(x) error("f3 " .. type(x)) end
local fe = {f1, f2, f3}
local function esite(f, v) return f(v) end
for rep = 1, 4 do
  for k = 1, #fe do
    for i = 1, 5 do try(esite, fe[k], i % 2 == 0 and {a = i} or nil) end
  end
end
