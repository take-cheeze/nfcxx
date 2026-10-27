// rustc: E0506
// nfcxx: error
// diag: loan-conflict
// Iterating a Vec<&i32> reads the references it holds, and the loop body assigns their referent.
fn main() {
    let mut x = 1;
    let mut v: Vec<&i32> = Vec::new();
    v.push(&x);
    for r in &v {
        x += **r;
    }
}
