// PUSHTRAP and POPTRAP, a throw, and a catch that reads the thrown value.
local r = 0
try {
  r = 1
  throw 42
  r = 2
} catch (e) {
  r = r + e
}
return r
