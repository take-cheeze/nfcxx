-- Many finalizable objects from a loop: the unreachable ones are finalized at a collection, newest first; the rest at exit.
-- The automatic collector is stopped, so that only the explicit collections finalize anything.
collectgarbage("stop")
local mt = {__gc = function(o) io.write(o.i, " ") end}
for i = 1, 5 do setmetatable({i = i}, mt) end
collectgarbage()
print()
local keep = {}
for i = 6, 7 do keep[i] = setmetatable({i = i}, mt) end
return "x"
