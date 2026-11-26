// Recursion: each level has its own frame on the shared stack.
function fib(n) {
  if (n < 2) return n;
  return fib(n - 1) + fib(n - 2);
}
return fib(12);
