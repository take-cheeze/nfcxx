// expect: tostring of an instance without _tostring is not lowered (the reference prints its address)
// The reference prints `(instance : 0x...)` with the address of the instance, which differs on every run.
class C { x = 1 }
local c = C();
print(c);
return 0;
