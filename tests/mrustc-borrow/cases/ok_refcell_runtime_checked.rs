// rustc: ok
// nfcxx: ok
// A Ref and a RefMut of one RefCell at once. RefCell checks its borrows when the program runs (this one
// panics at borrow_mut), so neither rustc nor this route rejects it.
use std::cell::RefCell;
fn main() {
    let c = RefCell::new(1);
    let a = c.borrow();
    let mut b = c.borrow_mut();
    *b += *a;
}
