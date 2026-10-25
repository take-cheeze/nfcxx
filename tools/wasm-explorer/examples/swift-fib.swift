// Swift: recursive functions and a loop over Int. Runs in both modes. The print calls write through the browser's
// console; main returns 0 (Swift's top-level code), so the expected result is 0.
func fib(_ n: Int) -> Int {
    if n < 2 {
        return n
    }
    return fib(n - 1) + fib(n - 2)
}

var total = 0
var i = 0
while i < 10 {
    total += fib(i)
    i += 1
}
print(total)
print(fib(20))
print(total > 80 && fib(3) == 2)
