// rustc: E0505
// nfcxx: error
// A RefCell moved while a RefMut guard of it is still used.
use std::cell::RefCell;
fn main() {
    let c = RefCell::new(1);
    let mut g = c.borrow_mut();
    let d = c;
    *g = 2;
    println!("{}", d.replace(3));
}
