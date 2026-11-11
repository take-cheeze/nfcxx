// rustc: ok
// nfcxx: error
// diag: loan-conflict: var0
// Rejected where rustc accepts: the program also calls `set` with an explicit `&mut` first argument,
// and the translator tells those calls from autoref'd ones only by the callee's name, so the
// receiver of `c.set(c.get())` is not two-phase here.
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
    C::set(&mut c, 2);
    c.set(c.get());
    let _n = c.n;
}
