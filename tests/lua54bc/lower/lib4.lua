local function f(...) return select('#', ...), select(2, ...) end
return f(7, 8, 9)
