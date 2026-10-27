// rustc: E0502
// nfcxx: error
// diag: loan-conflict: var0
// An explicit `&mut c` receiver is not an autoref, so it is not two-phase either.
struct C {
    n: i32,
}
impl C {
    fn get(&self) -> i32 {
        self.n
    }
    fn set(&mut self, v: i32) {
        self.n = v;
    }
}
fn main() {
    let mut c = C { n: 1 };
    (&mut c).set(c.get());
    let _n = c.n;
}
