local o = setmetatable({}, {__tostring = function() return "OBJ" end})
print(o, tostring(o))
return tostring(o) .. "!"
