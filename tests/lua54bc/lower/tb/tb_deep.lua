-- a deep stack: lauxlib's traceback shows the first 10 levels and the last 11, with the number skipped
local function down(n)
  if n == 0 then
    error("bottom")
  end
  local r = down(n - 1)
  return r
end

down(30)
