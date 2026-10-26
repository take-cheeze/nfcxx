// rustc: E0505
// nfcxx: ok
// Not detected yet: a move out of a borrowed local. The translator lowers the move as a copy and the
// borrow's later use reads the original, so neither mrustc's MIR validation nor the checker sees it.
struct S {
    v: i32,
}
fn take(s: S) -> i32 {
    s.v
}
fn main() {
    let a = S { v: 1 };
    let r = &a;
    let _b = take(a);
    let _c = r.v;
}
