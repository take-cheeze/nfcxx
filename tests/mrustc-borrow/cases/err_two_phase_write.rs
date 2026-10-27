// rustc: E0506
// nfcxx: error
// diag: loan-conflict: var0
// A reserved two-phase borrow still forbids writes: the argument assigns to the receiver's place.
struct C {
    n: i32,
}
impl C {
    fn set(&mut self, v: i32) {
        self.n = v;
    }
}
fn main() {
    let mut c = C { n: 1 };
    c.set({
        c.n = 5;
        1
    });
    let _n = c.n;
}
