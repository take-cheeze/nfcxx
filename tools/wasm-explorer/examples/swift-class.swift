// Swift: a class (reference counted, with an initializer and a method). Its object is on the heap, so it runs in the
// AddressSanitizer mode, whose allocator is the module's own (lp64 has no heap: the static build has that mode only).
class Counter {
    var count: Int
    init(start: Int) {
        count = start
    }
    func bump() {
        count += 1
    }
}

let c = Counter(start: 40)
c.bump()
c.bump()
print(c.count)
