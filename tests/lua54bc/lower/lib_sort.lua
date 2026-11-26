local t = {5, 2, 8, 1, 9, 3}
table.sort(t)
print(table.concat(t, " "))
table.sort(t, function(a, b) return a > b end)
print(table.concat(t, " "))
local words = {"pear", "apple", "fig", "banana"}
table.sort(words)
print(table.concat(words, ","))
local recs = {}
for i = 1, 30 do recs[i] = {k = (i * 7) % 11, id = i} end
table.sort(recs, function(a, b)
  if a.k ~= b.k then return a.k < b.k end
  return a.id < b.id
end)
local out = {}
for i, r in ipairs(recs) do out[#out + 1] = r.k .. ":" .. r.id end
print(table.concat(out, " "))
local big = {}
for i = 1, 500 do big[i] = (i * 7919) % 1000 end
table.sort(big)
local ok = true
for i = 2, #big do if big[i - 1] > big[i] then ok = false end end
print(ok, big[1], big[500])
table.sort({})
local one = {42}
table.sort(one)
local mixed = {3.5, 1, 2.25}
table.sort(mixed)
print(one[1], mixed[1], mixed[2], mixed[3])
return "sorted"
