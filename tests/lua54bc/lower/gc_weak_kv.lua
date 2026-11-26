-- Weak keys and values: an entry goes when its key or its value is not referred to elsewhere.
local t = setmetatable({}, {__mode = "kv"})
local k = {}
t[k] = "v-string"
t[1] = {}
t[{}] = 5
local keep = {}
t[keep] = keep
collectgarbage()
local n = 0
for _ in pairs(t) do n = n + 1 end
return t[k], t[keep] == keep, n
