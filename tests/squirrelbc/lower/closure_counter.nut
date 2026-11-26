// A closure that writes its outer variable (SETOUTER) and keeps it after its creating function has returned (the frame's
// outer variables are closed when it returns).
function make() {
  local n = 0;
  return function() { n = n + 1; return n; };
}
local c = make();
c();
c();
return c() * 10 + make()();
