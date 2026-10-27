// rustc: E0502
// nfcxx: error
// diag: loan-conflict: var0
// `+=` spelled as the call it stands for: the written `&mut c` is not two-phase. Calls to add_assign
// elsewhere in the program lose their two-phase borrows too (gap_two_phase_same_name).
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
    AddAssign::add_assign(&mut c, c.get());
    let _n = c.n;
}
