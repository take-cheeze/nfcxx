// rustc: E0499
// nfcxx: error
// diag: loan-conflict: var0
// The argument's own `&mut c` (another receiver) activates while the outer receiver is reserved.
struct C {
    n: i32,
}
impl C {
    fn set(&mut self, v: i32) {
        self.n = v;
    }
    fn bump(&mut self) -> i32 {
        self.n += 1;
        self.n
    }
}
fn main() {
    let mut c = C { n: 1 };
    c.set(c.bump());
    let _n = c.n;
}
