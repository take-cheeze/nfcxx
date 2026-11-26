-- The length operator on tables with holes: the border that luaH_getn finds for each shape a program builds.
local function show(name, t) print(name, #t) end

show("ctor 1 nil 3", {1, nil, 3})
show("ctor nil nil 3", {nil, nil, 3})
show("ctor 1 2 nil 4", {1, 2, nil, 4})
show("ctor 1 nil", {1, nil})
show("ctor nil", {nil})
show("ctor 1 nil nil nil 5", {1, nil, nil, nil, 5})
show("ctor 4 nils 5", {nil, nil, nil, nil, 5})
show("ctor hash and array", {n = 3, 1, 2, nil, 4})
show("ctor trailing nils", {1, 2, 3, nil, nil})

local t = {}
t[1] = 1; t[2] = 2; t[4] = 4
show("assign 1 2 4", t)

t = {}
t[2] = 2
show("assign 2", t)

t = {}
t[1] = 1; t[3] = 3
show("assign 1 3", t)

t = {}
for i = 1, 10 do t[i] = i end
t[5] = nil
show("ten, hole at 5", t)
t[10] = nil
show("ten, hole, 10 removed", t)
t[9] = nil; t[8] = nil
show("ten, 8 9 10 removed", t)

t = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10}
t[10] = nil; t[9] = nil
show("ctor ten, two off the end", t)
t[2] = nil
show("ctor ten, then 2 removed", t)

t = {1, 2, 3}
t[2] = nil
show("three, middle removed", t)

t = {}
for i = 1, 5 do table.insert(t, i) end
t[#t] = nil
show("insert five, pop", t)
t[#t + 1] = "x"
show("then push", t)

t = {}
for i = 1, 100 do t[i] = i end
for i = 100, 50, -1 do t[i] = nil end
show("hundred, top half removed", t)
for i = 1, 100 do t[i] = i end
for i = 1, 100, 3 do t[i] = nil end
show("hundred, every third removed", t)

t = {}
for i = 1, 20 do t[i * 2] = i end
show("even keys", t)

t = {}
t[1] = 1; t[2] = nil; t[3] = 3
show("1 nil 3 by assignment", t)

t = {}
t[-1] = 1; t[0] = 0; t[1] = 1; t[2] = 2
show("with negative and zero", t)

t = {}
t[1.0] = 1; t[2.0] = 2; t[4.0] = 4
show("float keys", t)

t = {}
for i = 1, 1000 do t[i] = true end
for i = 1, 1000, 3 do t[i] = nil end
show("thousand, thirds removed", t)
for i = 1000, 1, -1 do t[i] = nil end
show("thousand, all removed", t)

local function count(...) return #{...} end
show("vararg 1 nil 3", {count(1, nil, 3)})
print("vararg", count(1, nil, 3), count(nil, nil), count(1, nil), count())

local p = table.pack(1, nil, 3)
print("pack", p.n, #p)
p = table.pack(nil, nil)
print("pack nils", p.n, #p)

-- the border is stable: asking twice gives the same answer
t = {1, nil, 3, nil, 5}
print("stable", #t, #t)
