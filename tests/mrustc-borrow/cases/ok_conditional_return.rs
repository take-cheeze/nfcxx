// rustc: ok
// nfcxx: ok
// A borrow returned on one path, and the same place written and returned on the other.
fn first_or_reset(v: &mut (i32, bool)) -> &mut i32 {
    if v.1 {
        let r = &mut v.0;
        return r;
    }
    v.0 = 5;
    &mut v.0
}
fn main() {
    let mut p = (1, true);
    *first_or_reset(&mut p) += 1;
}
