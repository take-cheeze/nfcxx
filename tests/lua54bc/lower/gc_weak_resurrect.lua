-- A resurrected object (one a finalizer is due for) is removed from weak values before its finalizer runs, but stays as a
-- weak key until the next collection, which frees it after the finalizer.
local wk = setmetatable({}, {__mode = "k"})
local wv = setmetatable({}, {__mode = "v"})
local mt = {__gc = function(o) print("gc", o.name) end}
local o = setmetatable({name = "o"}, mt)
wk[o] = "value"
wv[1] = o
o = nil
collectgarbage()
local function count(t)
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n
end
print("after first", count(wk), count(wv))
collectgarbage()
print("after second", count(wk), count(wv))
return "end"
