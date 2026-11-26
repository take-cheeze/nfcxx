-- __pairs: pairs calls the metamethod with the table and returns its three results.
local proxy = setmetatable({}, {__pairs = function(t)
  return function(_, k)
    if k == nil then return 1, "one" end
    if k == 1 then return 2, "two" end
  end, t, nil
end})
for k, v in pairs(proxy) do print("pairs", k, v) end

-- the metamethod may return next itself
local lib = setmetatable({a = 1}, {__pairs = function(t) return next, t, nil end})
local count = 0
for k, v in pairs(lib) do count = count + 1; print(k, v) end
print("count", count)

-- fewer results than three are padded with nil, more are cut
print(select("#", pairs(setmetatable({}, {__pairs = function() return 1 end}))))
local a, b, c, d = pairs(setmetatable({}, {__pairs = function() return 1, 2, 3, 4 end}))
print(a, b, c, d)

-- without __pairs, pairs returns next, the table and nil
local t = {10}
local f, s, i = pairs(t)
print(f == next, s == t, i)
for k, v in pairs({}) do print("never") end
print(pcall(function() return pairs() end))
