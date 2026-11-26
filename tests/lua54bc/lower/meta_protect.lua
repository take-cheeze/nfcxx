-- __metatable: getmetatable returns the field, setmetatable refuses to change the metatable of such a table.
local locked = setmetatable({}, {__metatable = "locked"})
print(getmetatable(locked))
print(pcall(function() return setmetatable(locked, {}) end))
print(pcall(function() return setmetatable(locked, nil) end))

-- a false field is still a field: getmetatable returns it and setmetatable still refuses
local off = setmetatable({}, {__metatable = false})
print(getmetatable(off))
print(pcall(function() return setmetatable(off, {}) end))

-- a table field is returned as it is
local inner = setmetatable({}, {__metatable = {tag = "t"}})
print(getmetatable(inner).tag)

-- without the field, getmetatable returns the metatable and setmetatable changes it
local plain = setmetatable({}, {__index = {x = 7}})
print(getmetatable(plain).__index.x, plain.x)
setmetatable(plain, {__index = {x = 8}})
print(plain.x)
print(getmetatable(setmetatable({}, nil)))

-- strings have the string metatable; nil and numbers have none
print(getmetatable("abc").__index == string)
print(getmetatable(nil), getmetatable(1))

-- argument errors
print(pcall(function() return setmetatable(1, {}) end))
print(pcall(function() return setmetatable({}, 1) end))
print(pcall(function() return setmetatable({}) end))
print(pcall(function() return getmetatable() end))
