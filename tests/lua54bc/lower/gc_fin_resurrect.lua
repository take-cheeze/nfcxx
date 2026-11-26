-- A finalizer may keep its object. A weak value is cleared before the finalizer runs, so it is gone from the weak table;
-- the object lives on in what the finalizer saved, and is freed once that is dropped.
local saved
local mt = {__gc = function(o) print("finalizing", o.name) saved = o end}
local weak = setmetatable({}, {__mode = "v"})
local x = setmetatable({name = "x"}, mt)
weak[1] = x
x = nil
collectgarbage()
print("weak[1]", weak[1])
print("saved", saved and saved.name)
saved = nil
collectgarbage()
return "ok"
