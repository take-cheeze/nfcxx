local out = {}
for w in string.gmatch("one two  three", "%a+") do out[#out + 1] = w end
print(table.concat(out, ","))
local t = {}
for k, v in string.gmatch("a=1, b=2, c=3", "(%w+)=(%w+)") do t[#t + 1] = k .. ":" .. v end
print(table.concat(t, " "))
t = {}
for p in string.gmatch("abc", "()") do t[#t + 1] = p end
print(table.concat(t, ","))
t = {}
for w in string.gmatch("abc", "x*") do t[#t + 1] = "[" .. w .. "]" end
print(table.concat(t))
t = {}
for w in string.gmatch("hello world", "%a*", 3) do t[#t + 1] = w end
print(table.concat(t, "|"))
t = {}
for a in string.gmatch("", "a") do t[#t + 1] = a end
print(#t)
local it = string.gmatch("1 22 333", "%d+")
print(it(), it(), it(), it())
t = {}
for w in string.gmatch("aaa", "^a") do t[#t + 1] = w end
print(#t)
t = {}
for w in string.gmatch("a1b22c333", "%a(%d+)") do t[#t + 1] = w end
print(table.concat(t, " "))
local n = 0
for w in string.gmatch("the cat sat", "%a+") do n = n + #w end
print(n)
t = {}
for w in string.gmatch("abc", "b", 10) do t[#t + 1] = w end
print(#t)
local g1 = string.gmatch("xy", "%a")
local g2 = string.gmatch("pq", "%a")
print(g1(), g2(), g1(), g2(), g1())
