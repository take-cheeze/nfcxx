-- A weak cache of finalizable objects, filled while the collector runs on its own: the objects that are still referred to
-- stay with their entries, the others go, and the table keeps no entry for a dead key or value.
local cache = setmetatable({}, {__mode = "kv"})
local live = {}
local finalized = 0
local mt = {__gc = function(o) finalized = finalized + 1 end}
for i = 1, 2000 do
  local o = setmetatable({i = i}, mt)
  cache[i] = o
  cache["s" .. i] = {i}
  if i % 3 == 0 then live[#live + 1] = o end
end
collectgarbage()
local n, strs = 0, 0
for k, v in pairs(cache) do
  n = n + 1
  if type(k) == "string" then strs = strs + 1 end
end
local ok = true
for _, o in ipairs(live) do
  if cache[o.i] ~= o then ok = false end
end
return n, strs, ok, #live, finalized > 0
