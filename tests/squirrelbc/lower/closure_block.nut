// A local captured in a block: CLOSE at the end of the block moves its value into the outer variable, and the closure
// reads that value after the block.
local f = null;
{
  local z = 40;
  f = function() { return z + 2; };
}
local w = 7;
return f() + w;
