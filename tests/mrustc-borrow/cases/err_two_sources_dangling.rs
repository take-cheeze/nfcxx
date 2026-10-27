// rustc: E0597
// nfcxx: error
// The result of `pick` may borrow from `y`, which ends before the result is used.
fn pick<'a>(a: &'a i32, b: &'a i32, c: bool) -> &'a i32 {
    if c { a } else { b }
}
fn main() {
    let x = 1;
    let r;
    {
        let y = 2;
        r = pick(&x, &y, false);
    }
    let _v = *r;
}
