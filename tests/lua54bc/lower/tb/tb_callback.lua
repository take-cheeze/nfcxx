-- a function called by a library function has no name from the code: "in function <file:line>", under "[C]"
local values = {3, 1, 2}

local function compare(a, b)
  if a == 2 then
    error("cannot compare 2")
  end
  return a < b
end

local function sorted()
  table.sort(values, compare)
  return values
end

sorted()
