local function show(...) print(...) end
-- sieve
local function sieve(n)
  local is = {} for i = 2, n do is[i] = true end
  for i = 2, math.floor(math.sqrt(n)) do if is[i] then for j = i * i, n, i do is[j] = false end end end
  local c = 0 for i = 2, n do if is[i] then c = c + 1 end end return c
end
show(sieve(100), sieve(10000))
-- n queens
local function queens(n)
  local cols, d1, d2, count = {}, {}, {}, 0
  local function place(r)
    if r > n then count = count + 1 return end
    for c = 1, n do
      if not cols[c] and not d1[r + c] and not d2[r - c + n] then
        cols[c], d1[r + c], d2[r - c + n] = true, true, true
        place(r + 1)
        cols[c], d1[r + c], d2[r - c + n] = nil, nil, nil
      end
    end
  end
  place(1) return count
end
show(queens(6), queens(7), queens(8))
-- quicksort and mergesort implemented in the language
local function qsort(t, lo, hi)
  lo, hi = lo or 1, hi or #t
  if lo < hi then
    local p, i = t[hi], lo - 1
    for j = lo, hi - 1 do if t[j] <= p then i = i + 1 t[i], t[j] = t[j], t[i] end end
    t[i + 1], t[hi] = t[hi], t[i + 1]
    qsort(t, lo, i) qsort(t, i + 2, hi)
  end
  return t
end
local seed = 12345
local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed end
local arr = {} for i = 1, 500 do arr[i] = rnd() % 1000 end
local sorted = qsort(arr)
local ok = true for i = 2, #sorted do if sorted[i - 1] > sorted[i] then ok = false end end
show(ok, sorted[1], sorted[#sorted], #sorted)
local function msort(t)
  if #t <= 1 then return t end
  local mid = #t // 2 local l, r = {}, {}
  for i = 1, mid do l[#l + 1] = t[i] end for i = mid + 1, #t do r[#r + 1] = t[i] end
  l, r = msort(l), msort(r)
  local out, i, j = {}, 1, 1
  while i <= #l and j <= #r do if l[i] <= r[j] then out[#out + 1] = l[i] i = i + 1 else out[#out + 1] = r[j] j = j + 1 end end
  while i <= #l do out[#out + 1] = l[i] i = i + 1 end while j <= #r do out[#out + 1] = r[j] j = j + 1 end
  return out
end
local m = msort({5, 3, 9, 1, 7, 2, 8, 4, 6, 0}) show(table.concat(m, ","))
-- fibonacci memo, collatz, gcd, primes
local memo = {} local function mfib(n) if n < 2 then return n end if memo[n] then return memo[n] end local v = mfib(n - 1) + mfib(n - 2) memo[n] = v return v end
show(mfib(50), mfib(80))
local function collatz(n) local s = 0 while n ~= 1 do if n % 2 == 0 then n = n // 2 else n = 3 * n + 1 end s = s + 1 end return s end
show(collatz(27), collatz(97), collatz(871))
local function gcd(a, b) while b ~= 0 do a, b = b, a % b end return a end
show(gcd(48, 18), gcd(17, 5), gcd(1071, 462))
local function factors(n) local f = {} local d = 2 while n > 1 do while n % d == 0 do f[#f + 1] = d n = n // d end d = d + 1 end return f end
show(table.concat(factors(360), "*"), table.concat(factors(97), "*"), table.concat(factors(1001), "*"))
-- matrix multiplication
local function matmul(a, b, n)
  local c = {} for i = 1, n do c[i] = {} for j = 1, n do local s = 0 for k = 1, n do s = s + a[i][k] * b[k][j] end c[i][j] = s end end return c
end
local A, B = {}, {} for i = 1, 5 do A[i], B[i] = {}, {} for j = 1, 5 do A[i][j] = i + j B[i][j] = i * j end end
local C = matmul(A, B, 5) show(C[1][1], C[3][4], C[5][5])
-- floating point: mandelbrot row, newton sqrt, numeric integration
local function mandel(cx, cy) local x, y, i = 0.0, 0.0, 0 while i < 50 and x * x + y * y < 4.0 do x, y = x * x - y * y + cx, 2 * x * y + cy i = i + 1 end return i end
local row = {} for k = -10, 10 do row[#row + 1] = mandel(k / 10, 0.3) end show(table.concat(row, " "))
local function newton(v) local g = v / 2 for _ = 1, 20 do g = (g + v / g) / 2 end return g end
show(string.format("%.10f %.10f", newton(2), newton(144)))
local function integrate(f, a, b, n) local h, s = (b - a) / n, 0 for i = 0, n - 1 do s = s + f(a + (i + 0.5) * h) end return s * h end
show(string.format("%.6f %.6f", integrate(function(x) return x * x end, 0, 3, 1000), integrate(math.sin, 0, math.pi, 1000)))
-- string processing: word frequency, caesar cipher, palindromes, run-length encoding
local text = "the quick brown fox jumps over the lazy dog the fox"
local freq = {} for w in text:gmatch("%a+") do freq[w] = (freq[w] or 0) + 1 end
local ws = {} for w in pairs(freq) do ws[#ws + 1] = w end table.sort(ws, function(x, y) if freq[x] ~= freq[y] then return freq[x] > freq[y] end return x < y end)
local parts = {} for i = 1, 4 do parts[i] = ws[i] .. "=" .. freq[ws[i]] end show(table.concat(parts, " "))
local function caesar(s, k) return (s:gsub("%a", function(c) local base = c:match("%l") and 97 or 65 return string.char((c:byte() - base + k) % 26 + base) end)) end
show(caesar("Hello, World!", 3), caesar(caesar("Hello, World!", 3), -3))
local function ispal(s) s = s:lower():gsub("[^%a]", "") return s == s:reverse() end
show(ispal("A man, a plan, a canal: Panama"), ispal("hello"))
local function rle(s) local out = {} local i = 1 while i <= #s do local c = s:sub(i, i) local j = i while s:sub(j + 1, j + 1) == c do j = j + 1 end out[#out + 1] = (j - i + 1) .. c i = j + 1 end return table.concat(out) end
show(rle("aaabccddddd"), rle(""), rle("abc"))
-- a serializer with sorted keys, nested tables and escapes
local function ser(v, indent)
  indent = indent or ""
  if type(v) == "table" then
    local keys = {} for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    local out = {} for _, k in ipairs(keys) do out[#out + 1] = indent .. "  " .. tostring(k) .. ": " .. ser(v[k], indent .. "  ") end
    return "{\n" .. table.concat(out, ",\n") .. "\n" .. indent .. "}"
  elseif type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end
show(ser({name = "x", list = {1, 2, {a = true}}, n = 1.5, s = "q\"uote\n"}))
-- queue / stack / linked list classes with metatables
local Stack = {} Stack.__index = Stack
function Stack.new() return setmetatable({n = 0}, Stack) end
function Stack:push(v) self.n = self.n + 1 self[self.n] = v end
function Stack:pop() local v = self[self.n] self[self.n] = nil self.n = self.n - 1 return v end
local st = Stack.new() for i = 1, 5 do st:push(i * i) end show(st:pop(), st:pop(), st.n)
local list = nil for i = 1, 5 do list = {v = i, next = list} end
local lv = {} while list do lv[#lv + 1] = list.v list = list.next end show(table.concat(lv, ","))
-- binary trees (allocation heavy)
local function bottom_up(d) if d == 0 then return {} end return {bottom_up(d - 1), bottom_up(d - 1)} end
local function check(t) if t[1] then return 1 + check(t[1]) + check(t[2]) end return 1 end
local total = 0 for i = 1, 10 do total = total + check(bottom_up(8)) end show(total)
-- closures-based iterators and generators
local function chars(s) local i = 0 return function() i = i + 1 if i <= #s then return s:sub(i, i) end end end
local cc = {} for ch in chars("lua") do cc[#cc + 1] = ch:upper() end show(table.concat(cc))
-- string buffer and big concatenation
local buf = {} for i = 1, 200 do buf[#buf + 1] = i end show(#table.concat(buf, ","), (table.concat(buf, ","):gsub(",", "")):len())
-- varargs utilities
local function map(f, ...) local out = {} for i, v in ipairs({...}) do out[i] = f(v) end return table.unpack(out) end
show(map(function(x) return x * 2 end, 1, 2, 3))
-- deep recursion within limits
local function depth(n) if n == 0 then return 0 end return 1 + depth(n - 1) end
show(depth(1000))
-- integer overflow wraps, bit tricks
local function popcount(x) local c = 0 while x ~= 0 do c = c + (x & 1) x = x >> 1 end return c end
show(popcount(255), popcount(-1), popcount(0x5555555555555555), math.maxinteger + 1 == math.mininteger, 1 << 62)
local h = 5381 for ch in ("hash me"):gmatch(".") do h = ((h << 5) + h + ch:byte()) & 0xffffffff end show(h)
