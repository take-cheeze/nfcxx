// A map with a nine-parameter callback (nargs 10), made and called inside a function: the callee read below the
// map's frame is a register of the function that calls map.
local items = [3, 4, 5];
function run(x, y) {
  local r = items.map(function(p, b, c, d, e, f, g, h, i) { return b; });
  return r.len();
}
return run(1, 2);
