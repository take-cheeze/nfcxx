// rustc: E0506
// nfcxx: error
// Assigning to a local while a shared borrow of it is still used.
fn main() {
    let mut x = 1;
    let r = &x;
    x = 2;
    let _y = *r;
}
