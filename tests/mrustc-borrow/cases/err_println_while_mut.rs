// rustc: E0502
// nfcxx: error
// diag: loan-conflict
// println! borrows `x` while an exclusive borrow of it is still live.
fn main() {
    let mut x = 1;
    let m = &mut x;
    println!("{}", x);
    *m = 2;
}
