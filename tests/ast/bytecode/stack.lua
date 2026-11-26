-- Stack access (docs/notes/ast.md, "Bytecode stack access"): stack_get, stack_set and stack_top read and write the registers of the
-- running bytecode frame, as luac -l numbers them. This file runs only as a Lua 5.4 binary chunk (tests/ast/run.sh dumps it):
-- a source chunk has no bytecode frame to read.
local a, b = 10, 20
print("main", stack_top() > 2, stack_get(0), stack_get(1))
stack_set(1, 99)
print("set", b, stack_get(1))

local function probe(x, y)
  local z = x + y
  local w = stack_get(2)
  stack_set(2, z * 10)
  return z, w, stack_get(0), stack_get(1), stack_top()
end
print(probe(3, 4))

local function captured()
  local n = 5
  local function get() return n end
  print("captured", stack_get(0), get())
  stack_set(0, 42)
  print("after", get())
  return get
end
local g = captured()
print(g())

local function vf(first, ...)
  return stack_get(0), select("#", ...), stack_top() > 1
end
print(vf(7, 8, 9))

print(pcall(stack_get, 99))
print(pcall(stack_set, -1, 0))
print(pcall(function() return stack_get(1.5) end))
print(pcall(function() return stack_get("x") end))
print(pcall(function() return stack_get() end))
print(stack_get(1.0) == b, a)
