-- an error object that is a table without __tostring: "(error object is a table value)" and the traceback
local function fail()
  error({code = 7})
end

local function run()
  fail()
end

run()
