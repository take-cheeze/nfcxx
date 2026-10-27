// rustc: E0502
// nfcxx: error
// Cell::get_mut takes `&mut self`: an exclusive borrow while a shared reference to the cell is live.
use std::cell::Cell;
fn main() {
    let mut c = Cell::new(1);
    let r = &c;
    *c.get_mut() = 2;
    r.set(3);
}
