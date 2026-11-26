function sum(n) { return n === 0 ? 0 : n + sum(n - 1); }
var result = sum(100);
