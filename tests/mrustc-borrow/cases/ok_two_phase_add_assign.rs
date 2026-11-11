// rustc: ok
// nfcxx: ok
// An overloaded compound assignment borrows its left side two-phase: `c += c.get()` is
// `AddAssign::add_assign(&mut c, c.get())` with the `&mut c` reserved while the argument reads `c`.
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
    c += c.get();
    let _n = c.n;
}
