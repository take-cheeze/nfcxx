// rustc: E0597
// nfcxx: ok
// A `&mut` from a RefMut guard kept past the guard's drop. A `&mut T` is written through, so it points
// into the RefCell with the RefCell's loan, which the guard holds, and not with a loan of the guard. The
// checker keeps it within the RefCell's borrow, so it cannot dangle, but RefCell's runtime check no longer
// covers it.
use std::cell::RefCell;
fn main() {
    let c = RefCell::new(1);
    let x: &mut i32;
    {
        let mut g = c.borrow_mut();
        x = &mut *g;
    }
    *x = 2;
}
