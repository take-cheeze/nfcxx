// rustc: ok
// nfcxx: ok
// Cell::set through a shared reference while another shared reference to the cell is live: a write into
// the cell's UnsafeCell through a shared loan.
use std::cell::Cell;
fn main() {
    let c = Cell::new(1);
    let r = &c;
    let s = &c;
    r.set(2);
    s.set(s.get() + r.get());
    println!("{}", c.get());
}
