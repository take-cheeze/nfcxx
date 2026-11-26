function outer() {
  var a = 1;
  return function () { return a; };
}
var result = outer()();
