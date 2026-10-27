// rustc: E0505
// nfcxx: error
// diag: loan-conflict
// A move out of a borrowed local while the borrow is still used. The move is a move-value of the
// local's fields, which conflicts with the live shared loan.
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
