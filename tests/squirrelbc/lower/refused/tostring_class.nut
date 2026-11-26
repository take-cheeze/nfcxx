// expect: tostring of a class is not lowered (the reference prints its address)
// The reference prints `(class : 0x...)` with the address of the class, which differs on every run.
class C { x = 1 }
print(C);
return 0;
