local t = {}
t.x = 5
t[3] = 7
t["k"] = 2
return t.x + t[3] + t.k
