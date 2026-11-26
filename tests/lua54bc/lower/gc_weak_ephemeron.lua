-- Ephemerons: the value of a weak-key entry is kept while its key is alive, even if the value refers to the key; a key
-- that is kept alive only by its own value goes with the entry.
local eph = setmetatable({}, {__mode = "k"})
local a = {}
eph[a] = {}
eph[a].link = a
local b = {}
eph[b] = {ref = b}
b = nil
collectgarbage()
local n = 0
for k, v in pairs(eph) do n = n + 1 end
return n, eph[a] ~= nil, eph[a].link == a
