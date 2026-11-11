// rustc: ok
// nfcxx: ok
// A two-phase borrow: the receiver's `&mut c` is reserved, acting as a shared borrow, while the
// argument reads `c`, and becomes exclusive at the call, after the argument's borrow has ended.
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
    c.set(c.get() + 1);
    let _n = c.n;
}
