// Classes, inheritance, members, a constructor and a method call through a table.
class Base {
  x = 1
  constructor(v) { x = v }
  function get() { return x }
}
class Derived extends Base {
  y = 2
  function sum() { return get() + y }
}
local d = Derived(40)
return d.sum()
