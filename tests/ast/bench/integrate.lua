-- numerical integration: a loop that calls another kernel (through an upvalue) and reads a numeric upvalue
local scale = 0.5
local function f(x) return scale * x * x + 1.0 / (1.0 + x) end
local function integrate(a, b, n)
  local h = (b - a) / n
  local s = 0.0
  for i = 0, n - 1 do
    s = s + f(a + (i + 0.5) * h)
  end
  return s * h
end
local total = 0.0
for r = 1, 20 do total = total + integrate(0.0, 3.0, 500000) end
print(string.format("%.9f", total))
