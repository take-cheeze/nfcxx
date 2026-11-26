-- error objects: a number is its text with a traceback; a table with __tostring is its text alone
local function fail(v)
  error(v)
end

local which = ...
if which == nil then
  fail(42)
end
