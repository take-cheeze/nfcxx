// rustc: ok
// nfcxx: ok
// Disjoint fields can be borrowed mutably at the same time.
struct P {
    a: i32,
    b: i32,
}
fn main() {
    let mut p = P { a: 1, b: 2 };
    let x = &mut p.a;
    let y = &mut p.b;
    *x += 1;
    *y += 1;
    let _s = p.a + p.b;
}
