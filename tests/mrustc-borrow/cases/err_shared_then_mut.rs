// rustc: E0502
// nfcxx: error
// A shared borrow is live while an exclusive one is taken.
fn main() {
    let mut x = 1;
    let s = &x;
    let m = &mut x;
    *m += 1;
    let _y = *s;
}
