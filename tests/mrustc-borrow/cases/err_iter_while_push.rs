// rustc: E0502
// nfcxx: error
// diag: loan-conflict
// A push inside a loop over the Vec's iterator, which holds a shared borrow of it.
fn main() {
    let mut v: Vec<i32> = Vec::new();
    v.push(1);
    for x in v.iter() {
        v.push(*x);
    }
}
