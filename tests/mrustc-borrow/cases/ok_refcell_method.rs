// rustc: ok
// nfcxx: ok
// RefCell::borrow_mut and borrow through `&self` methods. The guard keeps references into the RefCell,
// and a write through RefMut's `&mut i32` is a write into the RefCell's UnsafeCell through the shared
// loan of `&self`.
use std::cell::RefCell;
struct Counter {
    n: RefCell<i32>,
}
impl Counter {
    fn bump(&self) {
        *self.n.borrow_mut() += 1;
    }
    fn get(&self) -> i32 {
        *self.n.borrow()
    }
}
fn main() {
    let c = Counter { n: RefCell::new(0) };
    let r = &c;
    c.bump();
    r.bump();
    println!("{}", c.get() + r.get());
}
