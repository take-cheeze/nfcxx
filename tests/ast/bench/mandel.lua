-- the iteration count of the Mandelbrot set at every point of a grid: float arithmetic, a while loop, multiple assignment
local function mandel(cx, cy, maxit)
  local x, y, i = 0.0, 0.0, 0
  while i < maxit and x * x + y * y <= 4.0 do
    x, y = x * x - y * y + cx, 2.0 * x * y + cy
    i = i + 1
  end
  return i
end
local total = 0
local n = 200
for row = 0, n - 1 do
  for col = 0, n - 1 do
    total = total + mandel(-2.0 + 3.0 * col / n, -1.5 + 3.0 * row / n, 200)
  end
end
print(total)
