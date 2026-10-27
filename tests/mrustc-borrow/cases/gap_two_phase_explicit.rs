// rustc: E0502
// nfcxx: ok
// Accepted where rustc is stricter: rustc makes only autoref borrows two-phase, and mrustc's MIR does
// not say whether a first argument's `&mut c` was written or autoref'd, so this one is two-phase too.
// The program is still memory-safe: `c` is only read before the call.
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
