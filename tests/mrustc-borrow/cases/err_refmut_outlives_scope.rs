// rustc: E0597
// nfcxx: error
// A RefMut guard kept past its RefCell's scope, through a write after the block.
use std::cell::{RefCell, RefMut};
fn main() {
    let mut g: RefMut<i32>;
    {
        let c = RefCell::new(1);
        g = c.borrow_mut();
    }
    *g = 3;
}
