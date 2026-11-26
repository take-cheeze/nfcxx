// A six-parameter callback (nargs 7) inside a function, after a null local: the callee read below the map's frame is
// the null, which is not callable.
function run(arr) {
  local n = null;
  local r = arr.map(function(p, b, c, d, e, f) { return b; });
  return r.len() + (n == null ? 0 : 1);
}
return run([1, 2]);
