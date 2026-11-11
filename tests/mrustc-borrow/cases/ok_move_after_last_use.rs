// rustc: ok
// nfcxx: ok
// The borrow is dead after its last use, so moving the local afterwards is allowed.
struct S {
    v: i32,
}
fn take(s: S) -> i32 {
    s.v
}
fn main() {
    let a = S { v: 1 };
    let r = &a;
    let _c = r.v;
    let _b = take(a);
}
