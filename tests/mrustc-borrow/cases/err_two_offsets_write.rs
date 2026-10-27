// rustc: E0506
// nfcxx: error
// diag: loan-conflict: var0[4..8]
// The result of `get` may borrow either field, so writing `m.b` while it is live conflicts.
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
    let r = get(&mut m, 0);
    m.b = 5;
    *r += 1;
}
