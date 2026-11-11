// rustc: ok
// nfcxx: ok
// Non-lexical lifetimes: the shared borrow is dead after its last use, so the assignment is allowed.
fn main() {
    let mut x = 1;
    let r = &x;
    let _y = *r;
    x = 2;
    let _z = x;
}
