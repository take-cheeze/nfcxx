// Float literals: LOADFLOAT for small values, LOAD of a literal for the rest.
local a = 1.5
local b = -0.25
local c = 1.0e10
local d = 3.14159265358979
local e = a * b + c / d
return e > 0.0
