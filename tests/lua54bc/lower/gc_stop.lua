-- collectgarbage("stop") and "restart" switch the collector; "isrunning" reports it, and an explicit collection still runs.
local a = collectgarbage("isrunning")
collectgarbage("stop")
local b = collectgarbage("isrunning")
local mt = {__gc = function() print("collected while stopped") end}
setmetatable({}, mt)
collectgarbage()
collectgarbage("restart")
return a, b, collectgarbage("isrunning")
