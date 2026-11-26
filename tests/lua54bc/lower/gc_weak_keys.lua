-- Weak keys: an entry whose key is only referenced by the table goes; a string key stays; a key that is still referenced stays.
local wk = setmetatable({}, {__mode = "k"})
local k1 = {}
local k2 = {}
wk[k1] = "one"
wk[k2] = "two"
wk.str = {}
wk[{}] = "gone"
k2 = nil
collectgarbage()
local n = 0
for k, v in pairs(wk) do n = n + 1 end
return wk[k1], wk.str ~= nil, n
