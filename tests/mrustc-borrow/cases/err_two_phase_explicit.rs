// rustc: E0502
// nfcxx: error
// diag: loan-conflict: var0
// rustc makes only autoref borrows two-phase, so an explicit `&mut c` first argument is exclusive from
// where it is written, and the next argument's `&c` conflicts with it. mrustc's MIR has the shape of a
// two-phase receiver; the AST dump says this `&mut` was written.
struct C {
    n: i32,
}
impl C {
    fn get(&self) -> i32 {
        self.n
    }
}
fn set(c: &mut C, v: i32) {
    c.n = v;
}
fn main() {
    let mut c = C { n: 1 };
    set(&mut c, c.get());
    let _n = c.n;
}
