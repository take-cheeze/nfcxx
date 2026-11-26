// Method calls: a method changes a field through `this` and returns `this`, so the calls chain; a method calls another method;
// a method takes an argument and reads a field of another instance.
class Counter {
  count = 0;
  function inc() { count = count + 1; return this; }
  function total() { return count; }
  function twice() { inc(); return inc().total(); }
}
class V {
  a = 0;
  function set(n) { a = n; return this; }
  function plus(m) { return a + m.a; }
}
local k = Counter();
print(k.inc().inc().total());
print(" ");
print(k.twice());
print(" ");
local p = V().set(3);
local q = V().set(4);
print(p.plus(q));
print(" ");
return q.plus(p);
