local names = {"a", "c", "d", "g", "l", "p", "s", "u", "w", "x", "z"}
for _, c in ipairs(names) do
  local n, m = 0, 0
  for i = 0, 255 do
    local ch = string.char(i)
    if string.find(ch, "%" .. c) then n = n + 1 end
    if string.find(ch, "%" .. c:upper()) then m = m + 1 end
  end
  print(c, n, m)
end
print(string.find(".", "%."), string.find("x", "%."))
print(string.match("hello123", "[a-z]+"), string.match("hello123", "[^a-z]+"))
print(string.match("x^y", "[%^]"), string.match("]", "[]]"), string.match("-", "[a-]"))
print(string.match("abc-def", "[%a-]+"), string.match("A_9z", "[%w_]+"))
local cnt = 0
for i = 0, 255 do
  if string.find(string.char(i), "[%w_]") then cnt = cnt + 1 end
end
print(cnt)
cnt = 0
for i = 0, 255 do
  if string.find(string.char(i), "[^%s]") then cnt = cnt + 1 end
end
print(cnt)
cnt = 0
for i = 0, 255 do
  if string.find(string.char(i), "[b-d]") then cnt = cnt + 1 end
end
print(cnt, string.match("zzz", "[a-c]"), string.match("cab", "[a-c]+"))
print(string.match("a^b", "a[%^]b"), string.match("a\tb", "a%sb"), string.match("a\0b", "a%zb") ~= nil)
