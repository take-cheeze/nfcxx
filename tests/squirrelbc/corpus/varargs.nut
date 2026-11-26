// Varargs: a function with vargv and vargc, and a tail call.
function count(...) {
  return vargc + vargv.len()
}
function tail(n) {
  return count(n, n)
}
return tail(7)
