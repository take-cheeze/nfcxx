-- Numbers and booleans are never collected, so they stay in weak tables; a function is collected when nothing refers to it,
-- and a global function stays.
local wk = setmetatable({}, {__mode = "k"})
wk[1] = {}
wk[2.5] = {}
wk[true] = {}
wk[print] = 1
local wv = setmetatable({}, {__mode = "v"})
wv[1] = 1
wv[2] = "x"
wv[3] = true
wv[4] = 2.5
wv[5] = {}
wv.f = function() return 1 end
wv.g = print
collectgarbage()
return wk[1] ~= nil, wk[2.5] ~= nil, wk[true] ~= nil, wk[print], wv[1], wv[2], wv[3], wv[4], wv[5], wv.f, wv.g == print
