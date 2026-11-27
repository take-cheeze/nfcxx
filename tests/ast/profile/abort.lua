-- an integer division by zero in compiled code abandons the run: the profiler must still see the enter closed
local function div(a, b) return a // b end
print(pcall(div, 7, 0))
