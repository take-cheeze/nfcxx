// rustc: E0382
// nfcxx: error
// diag: mrustc-mir-validation: ::"bin#"::main
// A use after a move. mrustc's own MIR validation rejects it before the checker runs: a moved-from
// local is no longer valid.
struct S {
    v: i32,
}
fn take(s: S) -> i32 {
    s.v
}
fn main() {
    let a = S { v: 1 };
    let _b = take(a);
    let _c = a.v;
}
