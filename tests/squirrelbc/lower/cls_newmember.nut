// _newmember of a class: a member declared in the class body after it calls _newmember with the key, the value, the
// attributes and the static flag, and is not added (NewSlotA). The members before it are added as usual.
class NM {
  before = 4;
  function _newmember(k, v, a, s) { print("member " + k + " "); }
  alpha = 1;
  function beta() { return 2; }
}
local n = NM();
print(" ");
return n.before;
