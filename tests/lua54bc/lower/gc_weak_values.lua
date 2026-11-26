-- A weak value goes when nothing else refers to it; a value that is still referred to stays; strings are never removed.
local cache = setmetatable({}, {__mode = "v"})
local keep = {name = "keep"}
cache.a = keep
cache.b = {name = "gone"}
cache[1] = {name = "arr"}
cache[2] = keep
cache.s = "string stays"
collectgarbage()
local n = 0
for k, v in pairs(cache) do n = n + 1 end
return cache.a == keep, cache.b, cache[1], cache[2] == keep, cache.s, n
