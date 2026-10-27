// rustc: E0506
// nfcxx: error
// Interior mutability is for writes through the cell's methods: assigning the Cell itself while a shared
// reference to it is live is still a conflict.
use std::cell::Cell;
fn main() {
    let mut c = Cell::new(1);
    let r = &c;
    c = Cell::new(2);
    r.set(3);
    println!("{}", c.get());
}
