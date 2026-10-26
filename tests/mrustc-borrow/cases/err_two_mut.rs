// rustc: E0499
// nfcxx: error
// Two exclusive borrows of the same local are live at once.
fn main() {
    let mut x = 1;
    let a = &mut x;
    let b = &mut x;
    *a += 1;
    *b += 1;
}
