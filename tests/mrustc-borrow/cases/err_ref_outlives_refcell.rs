// rustc: E0597
// nfcxx: error
// A Ref guard outlives its RefCell: the guard's drop at the end of main uses its reference to the
// RefCell's borrow flag, whose storage ended with the inner block.
use std::cell::{Ref, RefCell};
fn main() {
    let r: Ref<i32>;
    {
        let c = RefCell::new(1);
        r = c.borrow();
    }
    let _ = *r;
}
