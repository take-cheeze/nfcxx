// rustc: E0506
// nfcxx: error
// diag: loan-conflict
// A write through a Box while a reference to its contents is live.
fn main() {
    let mut b = Box::new(1);
    let r = &*b;
    *b = 2;
    println!("{}", r);
}
