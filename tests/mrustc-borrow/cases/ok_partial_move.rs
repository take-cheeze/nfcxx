// rustc: ok
// nfcxx: ok
// A struct without a Drop impl owes its fields' drops one by one. One field is moved out, on one
// branch only; mrustc drops it under a drop flag and the other field unconditionally.
struct Pair {
    a: Vec<i32>,
    b: Vec<i32>,
}
fn take(v: Vec<i32>) -> usize {
    v.len()
}
fn main() {
    let p = Pair { a: Vec::new(), b: Vec::new() };
    let c = p.b.len() == 0;
    if c {
        take(p.a);
    }
}
