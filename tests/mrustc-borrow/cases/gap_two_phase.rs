// rustc: ok
// nfcxx: error
// A false error: rustc's two-phase borrows let the receiver's exclusive borrow start after the
// shared argument borrow ends. The checker takes the exclusive loan first.
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
