// rustc: E0506
// nfcxx: error
// diag: loan-conflict: var1
// The result of `pick` may borrow from either argument, so writing the second one while it is live conflicts.
fn pick<'a>(a: &'a i32, b: &'a i32, c: bool) -> &'a i32 {
    if c { a } else { b }
}
fn main() {
    let x = 1;
    let mut y = 2;
    let r = pick(&x, &y, true);
    y = 3;
    let _v = *r;
}
