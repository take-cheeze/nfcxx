// A call of a class is an expression: the instance's method is called on its result, and the constructor's arithmetic runs
// on the argument.
class C {
  x = 0;
  constructor(a) { x = a * 10; }
  function get() { return x; }
}
print(C(4).get());
print(" ");
return C(4).get() + C(1).get();
