local a = {1, 2, 3, 4, 5}
table.move(a, 2, 4, 1)
print(table.concat(a, ","))
local c = {10, 20, 30, 40, 50}
table.move(c, 1, 3, 3)
print(table.concat(c, ","))
local d = table.move({7, 8, 9}, 1, 3, 2, {})
print(d[1], d[2], d[3], d[4])
print(table.move({}, 1, 0, 5) ~= nil)
local p = table.pack(1, nil, 3)
print(p.n, p[1], p[2], p[3])
print(table.pack().n)
return table.unpack(table.move({1, 2}, 1, 2, 1, {9, 9, 9}))
