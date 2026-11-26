print(string.gsub("hello world", "o", "0"))
print(string.gsub("hello world", "(%w+)", "<%1>"))
print(string.gsub("abc", "", "-"))
print(string.gsub("hello", "l", "L", 1))
print(string.gsub("$name is $age", "%$(%w+)", {name = "bob", age = 42}))
print(string.gsub("1 2 3", "%d", function(d) return d * 2 end))
print(string.gsub("a b", "%w", function(c) if c == "a" then return nil end return "X" end))
print(string.gsub("abc", "b", "%%"))
print(string.gsub("abc", "%w", "%0%0"))
print(string.gsub("hello world", "^h", "H"))
print(string.gsub("aaa", "^a", "b"))
print(string.gsub("x y", "(%w)", "%0", 0))
print(("abc"):gsub("b", "[%0]"))
print(string.gsub("one two", "(%w+) (%w+)", "%2 %1"))
print(string.gsub("abc", "()", "%1"))
local words = {}
for w in string.gmatch("the quick  brown fox", "%a+") do words[#words + 1] = w end
print(#words, words[1], words[4])
local kv = {}
for k, v in string.gmatch("a=1, b=2, c=3", "(%w+)=(%w+)") do kv[#kv + 1] = k .. v end
print(table.concat(kv, ";"))
local cnt = 0
for _ in string.gmatch("aaaa", "a*") do cnt = cnt + 1 end
print(cnt)
for pos in string.gmatch("abc", "()") do io.write(pos, " ") end
print()
return string.gsub("hello", "(l)(l)", "%2%1")
