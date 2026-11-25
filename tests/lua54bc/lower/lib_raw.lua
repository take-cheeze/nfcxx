local t = setmetatable({}, {__index = function() return "mm" end, __newindex = function() error("no") end})
rawset(t, "a", 1)
return rawget(t, "a"), rawget(t, "zz"), t.zz, rawequal(t, t), rawlen({1, 2, 3}), rawlen("abcd")
