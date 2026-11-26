-- The objects still alive when the state closes are finalized after the results are printed, newest first.
local mt = {__gc = function(o) print("exit gc", o.id) end}
local a = setmetatable({id = 1}, mt)
local b = setmetatable({id = 2}, mt)
print("main done")
return a.id + b.id
