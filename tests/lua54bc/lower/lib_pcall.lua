local function f(n) if n == 0 then error("deep") end return f(n - 1) end
local ok, msg = pcall(f, 3)
local ok2, v, w = pcall(function() return 7, 8 end)
return msg, v, w, ok, ok2
