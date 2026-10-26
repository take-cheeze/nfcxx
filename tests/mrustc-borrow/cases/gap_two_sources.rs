// rustc: ok
// nfcxx: refused
// A returned reference that may borrow from either argument: a summary names one source only.
fn pick<'a>(a: &'a i32, b: &'a i32) -> &'a i32 {
    if *a > *b { a } else { b }
}
fn main() {
    let x = 1;
    let y = 2;
    let r = pick(&x, &y);
    let _v = *r;
}
