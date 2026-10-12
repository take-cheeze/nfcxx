local function show(...) print(...) end
show(pcall(error, "msg"), pcall(error, "msg", 0), pcall(error, "msg", 2), pcall(error), pcall(error, nil), type(select(2, pcall(error, {code = 1}))))
show(select("#", pcall(error)), (pcall(error, 42)), select(2, pcall(error, 42)), select(2, pcall(error, true)))
show(pcall(function() error("lvl1") end), pcall(function() error("lvl2", 2) end), pcall(function() error("lvl0", 0) end))
show(pcall(function() error(setmetatable({}, {__tostring = function() return "tostr" end})) end))
local ok, e = pcall(function() error({code = 7, msg = "boom"}) end) show(ok, type(e), e.code, e.msg)
local t = {} local ok2, e2 = pcall(error, t) show(ok2, e2 == t)
-- runtime error messages
local u
show(pcall(function() return u.x end), pcall(function() return u() end), pcall(function() return u + 1 end))
show(pcall(function() return nofunc() end), pcall(function() return nofunc.x end), pcall(function() nofunc.x = 1 end))
show(pcall(function() local t = {} return t.a.b end), pcall(function() local t = {} t.a.b = 1 end), pcall(function() return ("x").y.z end))
show(pcall(function() return 1 + {} end), pcall(function() return {} + 1 end), pcall(function() return "a" + 1 end), pcall(function() return "10" + 1 end))
show(pcall(function() return 1 < "2" end), pcall(function() return {} < 1 end), pcall(function() return nil < 1 end), pcall(function() return "a" < 1 end))
show(pcall(function() return #5 end), pcall(function() return -{} end), pcall(function() return ~1.5 end), pcall(function() return 1 & 1.5 end), pcall(function() return "a" & 1 end))
show(pcall(function() return 1 // 0 end), pcall(function() return 1 % 0 end), pcall(function() return 2^63 | 0 end), pcall(function() return math.maxinteger // -1 end))
show(pcall(function() local a = "x" .. nil end), pcall(function() return {} .. {} end), pcall(function() local s = "a" return s .. u end))
show(pcall(function() for i = 1, "x" do end end), pcall(function() for i = "a", 2 do end end), pcall(function() for i = 1, 10, 0 do end end), pcall(function() for i = 1, 2, {} do end end))
show(pcall(function() local x <const> = 1 return x end), pcall(string.rep, "x", -1), pcall(("x").rep, "x", 1e10))
show(pcall(function() return setmetatable({}, {__index = function(t, k) error("idx " .. k) end}).foo end))
show(pcall(function() return math.floor("a") end), pcall(function() return ("x"):bad() end), pcall(function() return #print end))
-- error with levels through function calls
local function thrower(l) error("deep", l) end
local function mid(l) thrower(l) end
show(pcall(mid, 1), pcall(mid, 2), pcall(mid, 3))
-- nested pcall and rethrow
show(pcall(function() local ok, e = pcall(error, "inner") error("outer:" .. tostring(e), 0) end))
show(pcall(function() local ok, e = pcall(error, "x", 0) error(e, 0) end))
-- error in xpcall handler flow
show(xpcall(function() error("bad") end, function(m) return "handled: " .. m end))
show(xpcall(function(a, b) return a + b end, print, 3, 4))
show(xpcall(error, function(m) return type(m) end, {}))
-- assert
show(pcall(assert, false), pcall(assert, nil, "amsg"), pcall(assert, 1 == 1, "x"), select("#", assert(1, 2, 3)), type(select(2, pcall(assert, false, {1}))))
show(pcall(assert), pcall(assert, false, nil))
-- error values pass through unchanged
local ev = {} show(select(2, pcall(function() error(ev) end)) == ev, select(2, pcall(function() error(ev, 2) end)) == ev)
-- pcall returning values and passing arguments
show(pcall(function(...) return ... end, 1, 2, 3), pcall(pcall, error, "e"), pcall(pcall))
-- tostring of error objects
show(tostring(select(2, pcall(error, 12))), type(select(2, pcall(error, 12))), select(2, pcall(error, "s", 1)))
-- stack overflow is an error, not a crash
local function inf(n) return 1 + inf(n + 1) end
local ok3, e3 = pcall(inf, 1) show(ok3, type(e3) == "string" and e3:find("stack overflow") ~= nil)
-- error in the middle of table functions
show(pcall(table.concat, {1, {}, 3}), pcall(table.insert, nil, 1), pcall(ipairs), pcall(setmetatable, {}))
show(pcall(string.format, "%d", {}), pcall(tostring), pcall(tonumber), pcall(tonumber, "10", 99), pcall(tonumber, 10, 10))
-- load
local f = load("return 1 + 2") show(f())
show(load("syntax error here"), load("return +"))
show(pcall(load("error('from load')")), load("x ="))
local env_f = load("y_global = 5 return y_global") show(env_f(), y_global)
show(load("return ...", "chunk")(7, 8))
