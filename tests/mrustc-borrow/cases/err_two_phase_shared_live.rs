// rustc: E0502
// nfcxx: error
// diag: loan-conflict: var0
// A two-phase borrow conflicts at its activation, the call, with a shared borrow still live there.
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
    let r = &c;
    c.set(r.get());
    let _n = r.n;
}
