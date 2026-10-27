// rustc: E0502
// nfcxx: error
// diag: loan-conflict: var0
// The two-phase left side of `+=` still conflicts at the call with a shared borrow live there.
use std::ops::AddAssign;
struct C {
    n: i32,
}
impl C {
    fn get(&self) -> i32 {
        self.n
    }
}
impl AddAssign<i32> for C {
    fn add_assign(&mut self, v: i32) {
        self.n += v;
    }
}
fn main() {
    let mut c = C { n: 1 };
    let r = &c;
    c += r.get();
    let _n = r.n;
}
