-- Allocation inside and around inlined bodies, for the collector that runs at every function entry and loop iteration in the stress
-- runs: arguments that exist only on the stack while the body runs, tables and strings built in the body and returned, results
-- kept across further calls, strings that occur only in the body of a callee, and a chain of calls that each allocate.
local function pair(a, b) return {a, b} end
local function triple(a, b, c) return {first = a, second = b, third = c} end
local function join(a, b) return a .. "/" .. b end
local function wrap(s) return "<" .. s .. ">" end
local function rep(s, n) return s:rep(n) end
local function mk(n) return {n = n, name = "item" .. n, tags = {"t" .. n, "u" .. n}} end
local function label(it) return it.name .. ":" .. it.tags[1] .. it.tags[2] end
local function fresh() return {} end
local function constant_text() return "a string that only this function mentions, long enough to not be interned at all" end
local function constant_short() return "only-here" end

print("-- results kept alive across later calls")
local keep = {}
for i = 1, 40 do
  local a = pair(i, "s" .. i)
  local b = triple(a, pair(a, a), join("x" .. i, "y" .. i))
  local c = wrap(wrap(join(b.third, rep("ab", i % 5 + 1))))
  keep[#keep + 1] = {a, b, c}
end
local sum, len = 0, 0
for i, k in ipairs(keep) do
  sum = sum + k[1][1] + k[2].second[1][1]
  len = len + #k[3] + #k[2].third
end
print(#keep, sum, len, keep[40][3], keep[7][2].third)

print("-- arguments that are fresh objects, and a callee that allocates while they are only on the stack")
local function useboth(t, s) local junk = {t, s, "junk" .. #s} return #t + #s + #junk end
for i = 1, 30 do
  print(useboth({1, 2, i}, join("p", tostring(i))), label(mk(i)), join(label(mk(i)), label(mk(i + 1))))
end

print("-- strings that only a callee's body mentions")
local longs = {}
for i = 1, 20 do
  longs[#longs + 1] = constant_text() .. i
  longs[#longs + 1] = constant_short() .. i
  local junk = {}
  for j = 1, 10 do junk[j] = {j, tostring(j)} end
end
print(#longs, longs[1], longs[2], longs[39], longs[40])
print(constant_text() == constant_text(), constant_short() == "only-here")

print("-- many short-lived objects through a chain of calls")
local function level1(i) return {i, tostring(i)} end
local function level2(i) local t = level1(i); t[3] = level1(i + 1); return t end
local function level3(i) local t = level2(i); return {t, level2(i + 2), tostring(t[1] + t[3][1])} end
local acc = 0
for i = 1, 300 do
  local t = level3(i)
  acc = acc + t[1][1] + #t[2][2] + #t[3]
end
print(acc)

print("-- a table built in a callee and filled by the caller")
local rows = {}
for i = 1, 50 do
  local r = fresh()
  r.id = i
  r[1] = join("r", i)
  r.child = fresh()
  r.child.up = r
  rows[i] = r
end
local n = 0
for i, r in ipairs(rows) do n = n + r.id + #r[1] + (r.child.up == r and 1 or 0) end
print(n)

print("-- the collector sees through multiple results")
local function many(i) return i, "m" .. i, {i}, join("k", i) end
for i = 1, 20 do
  local a, b, c, d = many(i)
  local t = {many(i)}
  print(a, b, c[1], d, #t, t[2], t[3][1])
end
collectgarbage()
print(collectgarbage("count") > 0)
