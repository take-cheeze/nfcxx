-- numeric for with a NaN: Lua's forprep skips a float loop only when the start is beyond the limit (a NaN is beyond nothing, so the
-- body runs once); an integer loop with a NaN limit takes it as "less than the smallest integer": it does not run when counting up,
-- and counts down to math.mininteger otherwise
local nan = 0 / 0
local function count(f)
  local n = 0
  f(function() n = n + 1; return n >= 4 end)
  return n
end
print(count(function(stop) for i = nan, 3 do if stop() then break end end end))
print(count(function(stop) for i = 1, nan do if stop() then break end end end))
print(count(function(stop) for i = 1.0, nan do if stop() then break end end end))
print(count(function(stop) for i = nan, nan do if stop() then break end end end))
print(count(function(stop) for i = 1, 3, nan do if stop() then break end end end))
print(count(function(stop) for i = nan, 3, -1 do if stop() then break end end end))
print(count(function(stop) for i = 1, nan, -1 do if stop() then break end end end))
print(count(function(stop) for i = 3, nan, -1 do if stop() then break end end end))
print(count(function(stop) for i = 1.5, nan, -1 do if stop() then break end end end))
print(count(function(stop) for i = 1, nan, 2 do if stop() then break end end end))
print(count(function(stop) for i = 0, nan, -2 do if stop() then break end end end))
print(count(function(stop) for i = 3.0, nan, 0.5 do if stop() then break end end end))
print(count(function(stop) for i = -nan, 3.0, 0.5 do if stop() then break end end end))
for i = nan, 3 do print("float", i ~= i) end
for i = 2, nan, -1 do print("int", i); if i < 0 then break end end
for i = 1, nan, -1 do print("int", i); if i < -2 then break end end
for i = 1, 3, nan do print("nanstep", i) end
for i = 1.0, 3, nan do print("nanstep", i ~= i) end
local last
for i = math.maxinteger - 1, nan, -1 do last = i; if i < math.maxinteger - 3 then break end end
print(last)
for i = 1, 0/0 do print("never") end
for i = 1, -(0/0) do print("never") end
for i = 5, 1 do print("never") end
for i = 5.0, 1 do print("never") end
for i = 1.0, 5.0, -1 do print("never") end
print(pcall(function() for i = 1, 3, 0 do end end))
print(pcall(function() for i = 1.0, 3, 0 do end end))
print(pcall(function() for i = nan, 3, 0 do end end))
