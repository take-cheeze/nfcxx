local x <close> = setmetatable({}, {__close = function(_, e) print("closed", e) end})
error("boom")
