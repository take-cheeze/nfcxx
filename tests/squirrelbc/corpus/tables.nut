// Table and array literals, slots, a foreach over an array, and deletion.
local t = { a = 1, b = "two", [3] = 3.0 }
local arr = [1, 2, 3, "four", null, true]
t.c <- arr.len()
delete t.a
local total = 0
foreach (k, v in arr) {
  if (typeof v == "integer") total = total + v
}
return total + t.c
