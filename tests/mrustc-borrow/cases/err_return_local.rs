// rustc: E0515
// nfcxx: error
// diag: mrustc-lifetime: Lifetime bound
// A reference to a local returned from its function. mrustc's lifetime inference rejects it
// before MIR is built.
fn bad<'a>(_p: &'a i32) -> &'a i32 {
    let x = 1;
    &x
}
fn main() {
    let y = 2;
    let _v = *bad(&y);
}
