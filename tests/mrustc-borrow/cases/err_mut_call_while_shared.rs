// rustc: E0502
// nfcxx: error
// A mutable call argument conflicts with a shared borrow that is used later.
fn bump(v: &mut i32) {
    *v += 1;
}
fn main() {
    let mut x = 1;
    let s = &x;
    bump(&mut x);
    let _y = *s;
}
