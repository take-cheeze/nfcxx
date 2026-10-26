// rustc: ok
// nfcxx: ok
// Two calls that each borrow mutably for the call only. The callee's summary is inferred.
fn bump(v: &mut i32) {
    *v += 1;
}
fn main() {
    let mut x = 1;
    bump(&mut x);
    bump(&mut x);
    let _y = x;
}
