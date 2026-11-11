// rustc: ok
// nfcxx: ok
// A Copy type is copied, not moved, so passing it by value while it is borrowed is allowed.
#[derive(Clone, Copy)]
struct P {
    v: i32,
}
fn take(p: P) -> i32 {
    p.v
}
fn main() {
    let a = P { v: 1 };
    let r = &a;
    let _b = take(a);
    let _c = r.v;
}
