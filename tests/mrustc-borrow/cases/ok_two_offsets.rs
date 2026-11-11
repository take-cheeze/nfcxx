// rustc: ok
// nfcxx: ok
// NLL's "problem case 3", accepted by rustc 1.99. The result borrows one of two fields, so the summary of
// `get` lists both, and the write through the result may go to either.
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
