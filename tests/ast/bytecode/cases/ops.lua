-- The operators of the bytecode with immediates and constants (which Lua may swap or negate): comparisons with integers and floats,
-- shifts on either side, integer and float division and modulo, and the operand order the metamethods see.
local x, y = 3, 2.5
print(x < 1.5, x <= 3.0, x > 2.5, x >= 4, y < 3, y <= 2.5, y > 1, y >= 10)
print(x == 3, x == 3.0, y == 2.5, x ~= 3, 2^53 == 2^53 + 1)
print(x << 1, x >> 1, 1 << x, x >> -1, 1 >> 1, 0xff & 0x0f)
print(7 // 2, -7 // 2, 7 % -3, -7 % 3, 7.5 // 2, 2^10, 10 / 4)
print(x - 1, x + 1.5, 1 - x, x * 2, 2 * x, x // 0.0, -x)
print(x + 1, 1 + x, x - 2, x & 1, 1 | x, x ~ 1)

local mt = {
  __tostring = function() return "T" end,
  __sub = function(a, b) return "sub(" .. tostring(a) .. "," .. tostring(b) .. ")" end,
  __add = function(a, b) return "add(" .. tostring(a) .. "," .. tostring(b) .. ")" end,
  __shl = function(a, b) return "shl(" .. tostring(a) .. "," .. tostring(b) .. ")" end,
  __shr = function(a, b) return "shr(" .. tostring(a) .. "," .. tostring(b) .. ")" end,
  __mul = function(a, b) return "mul(" .. tostring(a) .. "," .. tostring(b) .. ")" end,
  __band = function(a, b) return "band(" .. tostring(a) .. "," .. tostring(b) .. ")" end,
  __lt = function(a, b) return true end,
  __le = function(a, b) return false end,
}
local t = setmetatable({}, mt)
print(t - 1, 1 + t, t + 1, t << 2, 3 << t, t >> 2, 2 * t, t * 2, t & 1)
print(t < 1, 1 < t, t <= 1, 1 >= t, t > 2, 2 > t)
print("10" + 1, "3" * "4", 10 .. 20, "2" ^ 2, -"3")
