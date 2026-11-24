local ok, e = pcall(error, {code = 1})
local ok2, e2 = pcall(function() error("boom", 0) end)
return e.code, e2, select('#', pcall(error))
