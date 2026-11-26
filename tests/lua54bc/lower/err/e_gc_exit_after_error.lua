-- The error is reported first; lua_close then runs the finalizer (on stdout).
setmetatable({}, {__gc = function() print("finalized after the error") end})
error("boom")
