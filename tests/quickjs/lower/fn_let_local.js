function f(n) {
  let s = 0;
  for (let i = 0; i < n; i++) s += i;
  return s;
}
var result = f(10) + f(3);
