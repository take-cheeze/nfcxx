// rustc: E0597
// nfcxx: error
// A reference from a Ref guard's deref kept past the guard's drop. It is modelled as a reference into
// the guard, with the guard's loan, which ends with the guard.
use std::cell::RefCell;
fn main() {
    let c = RefCell::new(1);
    let x: &i32;
    {
        let g = c.borrow();
        x = &*g;
    }
    println!("{}", x);
}
