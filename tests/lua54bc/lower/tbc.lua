local log = {}
local function closer(name)
  return setmetatable({}, {__close = function(o, e)
    log[#log + 1] = name .. ":" .. tostring(e)
  end})
end

do
  local a <close> = closer("a")
  local b <close> = closer("b")
  log[#log + 1] = "body"
end
print(table.concat(log, " "))
log = {}

local function f()
  local x <close> = closer("x")
  return "ret"
end
print(f(), table.concat(log, " "))
log = {}

do
  local n <close> = nil
  local q <close> = false
  log[#log + 1] = "nil and false are ignored"
end
print(table.concat(log, " "))
log = {}

print(pcall(function()
  local z <close> = closer("z")
  error("oops", 0)
end))
print(table.concat(log, " "))
log = {}

for i = 1, 3 do
  local c <close> = closer("i" .. i)
  if i == 2 then break end
end
print(table.concat(log, " "))
log = {}

local function iter()
  local function step(s, c) if c < 2 then return c + 1 end end
  return step, nil, 0, closer("loop")
end
for v in iter() do log[#log + 1] = "v" .. v end
print(table.concat(log, " "))
log = {}

local function two()
  local p <close> = closer("p")
  local r <close> = closer("r")
  return 1, 2
end
print(two(), table.concat(log, " "))
return "done"
