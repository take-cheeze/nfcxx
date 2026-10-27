// rustc: E0505
// nfcxx: error
// A Cell moved while a shared reference to it is still used. Cell has no drop glue, but a type that holds
// an UnsafeCell is never Copy, so the use is a move.
// diag: loan-conflict: var0
use std::cell::Cell;
fn take(_c: Cell<i32>) {}
fn main() {
    let c = Cell::new(1);
    let r = &c;
    take(c);
    r.set(2);
}
