// rustc: ok
// nfcxx: refused
// NLL's "problem case 3", accepted by rustc 1.99. The result borrows one of two fields, but a summary
// names one source range, so `get` has none and its body is refused.
struct M {
    a: i32,
    b: i32,
}
fn get(m: &mut M, k: i32) -> &mut i32 {
    let r = &mut m.a;
    if k == 0 {
        return r;
    }
    &mut m.b
}
fn main() {
    let mut m = M { a: 1, b: 2 };
    *get(&mut m, 0) += 1;
}
