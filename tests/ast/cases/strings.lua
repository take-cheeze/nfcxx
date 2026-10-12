local function show(...) print(...) end
local s = "Hello, World"
show(#s, s:len(), s:upper(), s:lower(), s:reverse(), s:sub(1, 5), s:sub(-5), s:sub(8, -1), s:sub(0), s:sub(100), s:sub(-100, 3), s:sub(3, 2))
show(s:byte(1), s:byte(-1), s:byte(1, 3), s:byte(100), string.char(72, 105), string.char())
show(("ab"):rep(3), ("ab"):rep(3, "-"), ("ab"):rep(0), ("ab"):rep(-1), ("x"):rep(1, "sep"))
show(s:find("World"), s:find("o"), s:find("o", 6), s:find("xyz"), s:find(""), s:find("", 20), s:find("l+"), s:find(".", 1, true), s:find("o", -3))
show(s:match("(%a+), (%a+)"), s:match("%d"), s:match("()ll()"), s:match("^Hello"), s:match("World$"), s:match("^World"))
show(("key=value"):match("(%w+)=(%w+)"), ("  trim  "):match("^%s*(.-)%s*$") .. "|", ("2024-01-15"):match("(%d+)-(%d+)-(%d+)"))
show(("abc"):gsub("b", "X"), ("abc"):gsub("", "-"), ("hello world"):gsub("o", "0", 1), ("abc"):gsub("%w", "%0%0"), ("abc"):gsub("(a)(b)", "%2%1"))
show(("hello"):gsub("l", {l = "L"}), ("hello"):gsub(".", function(c) return c:byte() .. "," end), ("abc"):gsub("b", function() return nil end))
show(("a,b,,c"):gsub(",", ";"), ("x"):gsub("x", "%%"), pcall(string.gsub, "x", "x", "%2"), pcall(string.gsub, "x", "(", "y"))
local words = {}
for w in ("the quick brown fox"):gmatch("%a+") do words[#words + 1] = w end
show(#words, table.concat(words, "|"))
for k, v in ("a=1, b=2, c=3"):gmatch("(%w+)=(%w+)") do io = nil; show(k, v) end
show(("abc"):gmatch(".")())
show(("f(a,b)"):match("%((.-)%)"), ("[[x]]"):match("%[%[(.*)%]%]"), ("THE (quick) fox"):find("%((%a+)%)"), ("a.b"):find(".", 1, true))
show(("%d"):rep(2), ("x"):byte(), ("é"):len(), "tab\there", "nl\\n", 'single "double"', "a\65\066\x41\u{48}\z
   continued")
show([[long
string]], [==[with ]] inside]==], #[[

x]])
show("abc" .. 1 .. 2.5 .. "d", 1 .. "", 1.0 .. "", -0.0 .. "", 2^63 .. "")
show(("test"):find("t", 2), ("a+b"):find("+", 1, true), ("a+b"):find("%+"), ("hello"):find("l", 1, true))
show(("%bxy"):len(), ("(foo(bar))baz"):match("%b()"), ("THE END"):lower():gsub("^%l", string.upper))
show(("word1 word2"):match("%f[%w]%w+"), ("key = val"):match("^(%w+)%s*=%s*(%w+)$"), ("abc123"):match("%a+(%d+)"))
show(tostring(nil), tostring(true), tostring(false), tostring(12), tostring("x"), type(tostring({})), tostring(print):sub(1, 9))
show(string.len("abc"), string.sub("abc", 2), string.upper("a"), ("x"):rep(3):upper())
show(pcall(string.rep), pcall(string.sub), pcall(("x").bad), pcall(string.char, 256), pcall(string.char, -1))
show(#("x"):rep(1000), ("ab"):rep(2, ","):len())
show(("one two"):find("(%w+) (%w+)"), ("abc"):find("b", nil), ("abc"):sub(2, 2), ("abc"):sub(-1, -1))
show(select("#", ("abc"):byte(1, -1)), (("x"):byte(1, 0)))
show(("CamelCaseString"):gsub("(%u)", " %1"), ("a b  c"):gsub("%s+", " "), ("path/to/file.txt"):match("([^/]+)$"), ("file.tar.gz"):match("^(.-)%.(.*)$"))
