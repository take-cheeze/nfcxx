// rustc: E0502
// nfcxx: error
// diag: loan-conflict
// A reference to an element is live across a push, which may move the elements.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    let r = &v[0];
    v.push(2);
    println!("{}", r);
}
