// _newslot of a class: a NEWSLOT on an instance calls it with the key and the value (NewSlot, sqvm.cpp), instead of the
// error that an instance without the metamethod gives.
class N {
  function _newslot(k, v) { print("new " + k + "=" + v + " "); }
}
local n = N();
n.z <- 3;
n.w <- "s";
print(" ");
return 0;
